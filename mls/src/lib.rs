use openmls::prelude::tls_codec::{
    Deserialize as TlsDeserializeTrait, Serialize as TlsSerializeTrait,
};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;
use openmls_traits::storage::StorageProvider;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

uniffi::setup_scaffolding!();

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_STATE: usize = 16 * 1024 * 1024;
const MAX_MESSAGE: usize = 384 * 1024;

#[derive(Debug, thiserror::Error, uniffi::Error, PartialEq)]
pub enum MlsError {
    #[error("Invalid MLS state or message")]
    InvalidInput,
    #[error("QR fingerprint does not match")]
    FingerprintMismatch,
    #[error("MLS operation is not valid in the current state")]
    InvalidState,
    #[error("MLS library rejected the operation")]
    LibraryRejected,
}

type Result<T> = std::result::Result<T, MlsError>;
fn protocol<T, E>(result: std::result::Result<T, E>) -> Result<T> {
    result.map_err(|_| MlsError::LibraryRejected)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    version: u8,
    identity: Vec<u8>,
    public_key: Vec<u8>,
    group_id: Option<Vec<u8>>,
    pending_commit: Option<Vec<u8>>,
    key_package: Option<Vec<u8>>,
    values: Vec<(Vec<u8>, Vec<u8>)>,
}

#[derive(uniffi::Record)]
pub struct MlsTransition {
    pub state: Vec<u8>,
    pub output: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub sender: Option<Vec<u8>>,
    pub removed: bool,
}

#[derive(uniffi::Record)]
pub struct MlsIdentity {
    pub state: Vec<u8>,
    pub key_package: Vec<u8>,
    pub fingerprint: Vec<u8>,
}

struct Client {
    snapshot: Snapshot,
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
}

impl Client {
    fn load(bytes: Vec<u8>) -> Result<Self> {
        let bytes = Zeroizing::new(bytes);
        if bytes.len() > MAX_STATE {
            return Err(MlsError::InvalidInput);
        }
        let mut snapshot: Snapshot =
            serde_json::from_slice(&bytes).map_err(|_| MlsError::InvalidInput)?;
        if snapshot.version != 2 || snapshot.identity.len() != 16 || snapshot.public_key.len() != 32
        {
            return Err(MlsError::InvalidInput);
        }
        let provider = OpenMlsRustCrypto::default();
        *provider
            .storage()
            .values
            .write()
            .map_err(|_| MlsError::InvalidState)? =
            std::mem::take(&mut snapshot.values).into_iter().collect();
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &snapshot.public_key,
            SUITE.signature_algorithm(),
        )
        .ok_or(MlsError::InvalidState)?;
        Ok(Self {
            snapshot,
            provider,
            signer,
        })
    }

    fn group(&self) -> Result<MlsGroup> {
        let id = self
            .snapshot
            .group_id
            .as_ref()
            .ok_or(MlsError::InvalidState)?;
        let group = protocol(MlsGroup::load(
            self.provider.storage(),
            &GroupId::from_slice(id),
        ))?
        .ok_or(MlsError::InvalidState)?;
        if !group.is_active() {
            return Err(MlsError::InvalidState);
        }
        Ok(group)
    }

    fn credential(&self) -> CredentialWithKey {
        CredentialWithKey {
            credential: BasicCredential::new(self.snapshot.identity.clone()).into(),
            signature_key: self.snapshot.public_key.clone().into(),
        }
    }

    fn save(
        mut self,
        output: Vec<u8>,
        welcome: Option<Vec<u8>>,
        group: Option<&MlsGroup>,
        sender: Option<Vec<u8>>,
        removed: bool,
    ) -> Result<MlsTransition> {
        let epoch = group.map_or(0, |g| g.epoch().as_u64());
        let group_id = self.snapshot.group_id.clone().unwrap_or_default();
        self.snapshot.values = self
            .provider
            .storage()
            .values
            .read()
            .map_err(|_| MlsError::InvalidState)?
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let state = serde_json::to_vec(&self.snapshot).map_err(|_| MlsError::InvalidState)?;
        if state.len() > MAX_STATE {
            return Err(MlsError::InvalidState);
        }
        Ok(MlsTransition {
            state,
            output,
            welcome,
            group_id,
            epoch,
            sender,
            removed,
        })
    }

    fn ready(&self) -> Result<()> {
        if self.snapshot.pending_commit.is_some() {
            Err(MlsError::InvalidState)
        } else {
            Ok(())
        }
    }
}

fn config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(SUITE)
        .use_ratchet_tree_extension(true)
        .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .max_past_epochs(0)
        .build()
}

fn encode(message: &MlsMessageOut) -> Result<Vec<u8>> {
    protocol(message.tls_serialize_detached())
}
fn decode(bytes: &[u8]) -> Result<MlsMessageIn> {
    if bytes.is_empty() || bytes.len() > MAX_MESSAGE + 65536 {
        return Err(MlsError::InvalidInput);
    }
    MlsMessageIn::tls_deserialize_exact(bytes).map_err(|_| MlsError::InvalidInput)
}
fn key_fingerprint(key: &[u8]) -> Vec<u8> {
    Sha256::digest(key).to_vec()
}
fn verify_key(key: &[u8], expected: &[u8]) -> Result<()> {
    if expected.len() != 32 || key_fingerprint(key) != expected {
        return Err(MlsError::FingerprintMismatch);
    }
    Ok(())
}

#[uniffi::export]
pub fn create_identity(device_id: Vec<u8>) -> Result<MlsIdentity> {
    if device_id.len() != 16 {
        return Err(MlsError::InvalidInput);
    }
    let provider = OpenMlsRustCrypto::default();
    let signer = protocol(SignatureKeyPair::new(SUITE.signature_algorithm()))?;
    protocol(signer.store(provider.storage()))?;
    let public_key = signer.to_public_vec();
    let fingerprint = key_fingerprint(&public_key);
    let mut client = Client {
        snapshot: Snapshot {
            version: 2,
            identity: device_id,
            public_key,
            group_id: None,
            pending_commit: None,
            key_package: None,
            values: vec![],
        },
        provider,
        signer,
    };
    let bundle = protocol(KeyPackage::builder().build(
        SUITE,
        &client.provider,
        &client.signer,
        client.credential(),
    ))?;
    let key_package = protocol(bundle.key_package().tls_serialize_detached())?;
    client.snapshot.key_package = Some(key_package.clone());
    let transition = client.save(vec![], None, None, None, false)?;
    Ok(MlsIdentity {
        state: transition.state,
        key_package,
        fingerprint,
    })
}

#[uniffi::export]
pub fn create_group(state: Vec<u8>, group_id: Vec<u8>) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    if client.snapshot.group_id.is_some() || group_id.len() != 32 {
        return Err(MlsError::InvalidState);
    }
    // Creating a group must not retain an unused joining KeyPackage's private keys.
    if let Some(bytes) = client.snapshot.key_package.take() {
        let kp = KeyPackageIn::tls_deserialize_exact(bytes).map_err(|_| MlsError::InvalidState)?;
        let kp = protocol(kp.validate(client.provider.crypto(), ProtocolVersion::Mls10))?;
        protocol(
            client
                .provider
                .storage()
                .delete_key_package(&protocol(kp.hash_ref(client.provider.crypto()))?),
        )?;
    }
    let group = protocol(MlsGroup::new_with_group_id(
        &client.provider,
        &client.signer,
        &config(),
        GroupId::from_slice(&group_id),
        client.credential(),
    ))?;
    client.snapshot.group_id = Some(group_id);
    client.save(vec![], None, Some(&group), None, false)
}

#[uniffi::export]
pub fn prepare_add(
    state: Vec<u8>,
    key_package: Vec<u8>,
    verified_fingerprint: Vec<u8>,
) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    client.ready()?;
    if key_package.len() > 65536 {
        return Err(MlsError::InvalidInput);
    }
    let kp =
        KeyPackageIn::tls_deserialize_exact(key_package).map_err(|_| MlsError::InvalidInput)?;
    let kp = protocol(kp.validate(client.provider.crypto(), ProtocolVersion::Mls10))?;
    verify_key(
        kp.leaf_node().signature_key().as_slice(),
        &verified_fingerprint,
    )?;
    let mut group = client.group()?;
    if group.members().count() >= 8
        || group.members().any(|m| {
            m.signature_key == kp.leaf_node().signature_key().as_slice()
                || m.credential == *kp.leaf_node().credential()
        })
    {
        return Err(MlsError::InvalidState);
    }
    let (commit, welcome, _) =
        protocol(group.add_members(&client.provider, &client.signer, &[kp]))?;
    let commit = encode(&commit)?;
    client.snapshot.pending_commit = Some(commit.clone());
    client.save(commit, Some(encode(&welcome)?), Some(&group), None, false)
}

#[uniffi::export]
pub fn prepare_remove(state: Vec<u8>, member_fingerprint: Vec<u8>) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    client.ready()?;
    let mut group = client.group()?;
    let member = group
        .members()
        .find(|m| key_fingerprint(&m.signature_key) == member_fingerprint)
        .ok_or(MlsError::InvalidInput)?;
    if member.index == group.own_leaf_index() {
        return Err(MlsError::InvalidInput);
    }
    let (commit, _, _) =
        protocol(group.remove_members(&client.provider, &client.signer, &[member.index]))?;
    let commit = encode(&commit)?;
    client.snapshot.pending_commit = Some(commit.clone());
    client.save(commit, None, Some(&group), None, false)
}

#[uniffi::export]
pub fn accept_commit(state: Vec<u8>, accepted_commit: Vec<u8>) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    if client.snapshot.pending_commit.as_ref() != Some(&accepted_commit) {
        return Err(MlsError::InvalidState);
    }
    let mut group = client.group()?;
    protocol(group.merge_pending_commit(&client.provider))?;
    client.snapshot.pending_commit = None;
    client.save(vec![], None, Some(&group), None, false)
}

#[uniffi::export]
pub fn discard_commit(state: Vec<u8>) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    if client.snapshot.pending_commit.is_none() {
        return Err(MlsError::InvalidState);
    }
    let mut group = client.group()?;
    protocol(group.clear_pending_commit(client.provider.storage()))?;
    client.snapshot.pending_commit = None;
    client.save(vec![], None, Some(&group), None, false)
}

#[uniffi::export]
pub fn join_group(
    state: Vec<u8>,
    welcome: Vec<u8>,
    expected_group_id: Vec<u8>,
    inviter_fingerprint: Vec<u8>,
) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    if client.snapshot.group_id.is_some() {
        return Err(MlsError::InvalidState);
    }
    let MlsMessageBodyIn::Welcome(welcome) = decode(&welcome)?.extract() else {
        return Err(MlsError::InvalidInput);
    };
    let staged = protocol(StagedWelcome::new_from_welcome(
        &client.provider,
        config().join_config(),
        welcome,
        None,
    ))?;
    verify_key(
        protocol(staged.welcome_sender())?
            .signature_key()
            .as_slice(),
        &inviter_fingerprint,
    )?;
    let group = protocol(staged.into_group(&client.provider))?;
    if group.group_id().as_slice() != expected_group_id {
        return Err(MlsError::InvalidInput);
    }
    client.snapshot.group_id = Some(expected_group_id);
    client.snapshot.key_package = None;
    client.save(vec![], None, Some(&group), None, false)
}

#[uniffi::export]
pub fn seal_message(state: Vec<u8>, plaintext: Vec<u8>) -> Result<MlsTransition> {
    let plaintext = Zeroizing::new(plaintext);
    let client = Client::load(state)?;
    client.ready()?;
    if plaintext.len() > MAX_MESSAGE {
        return Err(MlsError::InvalidInput);
    }
    let mut group = client.group()?;
    let message = protocol(group.create_message(&client.provider, &client.signer, &plaintext))?;
    client.save(encode(&message)?, None, Some(&group), None, false)
}

#[uniffi::export]
pub fn receive_message(state: Vec<u8>, message: Vec<u8>) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    let mut group = client.group()?;
    let message = decode(&message)?
        .try_into_protocol_message()
        .map_err(|_| MlsError::InvalidInput)?;
    let processed = protocol(group.process_message(&client.provider, message))?;
    let Sender::Member(index) = processed.sender() else {
        return Err(MlsError::InvalidInput);
    };
    let sender = key_fingerprint(
        &group
            .members()
            .find(|m| m.index == *index)
            .ok_or(MlsError::InvalidInput)?
            .signature_key,
    );
    match processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(message) => client.save(
            message.into_bytes(),
            None,
            Some(&group),
            Some(sender),
            false,
        ),
        ProcessedMessageContent::StagedCommitMessage(commit) => {
            let removed = commit.self_removed();
            protocol(group.merge_staged_commit(&client.provider, *commit))?;
            client.snapshot.pending_commit = None;
            client.save(vec![], None, Some(&group), None, removed)
        }
        _ => Err(MlsError::InvalidInput),
    }
}
