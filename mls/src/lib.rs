use openmls::prelude::tls_codec::{
    Deserialize as TlsDeserializeTrait, Serialize as TlsSerializeTrait,
};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;
use openmls_traits::random::OpenMlsRand;
use openmls_traits::storage::StorageProvider;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use zeroize::Zeroizing;

uniffi::setup_scaffolding!();

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_STATE: usize = 16 * 1024 * 1024;
const SNAPSHOT_VERSION: u8 = 4;
const KEY_PACKAGE_LIFETIME: u64 = 7 * 24 * 60 * 60;
const MAX_MESSAGE: usize = 384 * 1024;

#[derive(Debug, thiserror::Error, uniffi::Error, PartialEq)]
pub enum MlsError {
    #[error("Invalid MLS state or message")]
    InvalidInput,
    #[error("QR fingerprint does not match")]
    FingerprintMismatch,
    #[error("MLS operation is not valid in the current state")]
    InvalidState,
    #[error("MLS library rejected the operation: {code}")]
    LibraryRejected { code: String },
}

type Result<T> = std::result::Result<T, MlsError>;
fn protocol<T, E: std::fmt::Display>(result: std::result::Result<T, E>) -> Result<T> {
    result.map_err(|error| MlsError::LibraryRejected {
        code: error.to_string().chars().take(200).collect(),
    })
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    identity: Vec<u8>,
    public_key: Vec<u8>,
    group_id: Option<Vec<u8>>,
    pending_commit: Option<Vec<u8>>,
    key_package: Vec<Vec<u8>>,
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
    pub added_writer: Option<Vec<u8>>,
    pub removed_writer: Option<Vec<u8>>,
    pub departed: Option<Vec<u8>>,
}

#[derive(uniffi::Record)]
pub struct MlsIdentity {
    pub state: Vec<u8>,
    pub fingerprint: Vec<u8>,
    pub writer_token: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct MlsMember {
    pub device_id: Vec<u8>,
    pub fingerprint: Vec<u8>,
    pub writer_hash: Vec<u8>,
}

fn credential_identity(credential: &Credential) -> Result<(Vec<u8>, Vec<u8>)> {
    let credential =
        BasicCredential::try_from(credential.clone()).map_err(|_| MlsError::InvalidInput)?;
    let identity = credential.identity();
    if identity.len() != 48 {
        return Err(MlsError::InvalidInput);
    }
    Ok((identity[..16].to_vec(), identity[16..].to_vec()))
}

fn roster(group: &MlsGroup) -> Result<Vec<MlsMember>> {
    let mut identities = HashSet::new();
    let mut keys = HashSet::new();
    let mut writers = HashSet::new();
    let mut members = Vec::new();
    for member in group.members() {
        let (device_id, writer_hash) = credential_identity(&member.credential)?;
        if !writers.insert(writer_hash.clone())
            || member.signature_key.len() != 32
            || !identities.insert(device_id.clone())
            || !keys.insert(member.signature_key.clone())
        {
            return Err(MlsError::InvalidInput);
        }
        members.push(MlsMember {
            device_id,
            fingerprint: key_fingerprint(&member.signature_key),
            writer_hash,
        });
    }
    if members.is_empty() || members.len() > 8 {
        return Err(MlsError::InvalidInput);
    }
    Ok(members)
}

fn departing_fingerprints(group: &MlsGroup) -> HashSet<Vec<u8>> {
    group
        .pending_proposals()
        .filter_map(|queued| match queued.proposal() {
            Proposal::Remove(remove) => group
                .members()
                .find(|m| m.index == remove.removed())
                .map(|m| key_fingerprint(&m.signature_key)),
            _ => None,
        })
        .collect()
}

#[uniffi::export]
pub fn members(state: Vec<u8>) -> Result<Vec<MlsMember>> {
    roster(&Client::load(state)?.group()?)
}

struct Client {
    snapshot: Snapshot,
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
}

impl Client {
    fn load(bytes: Vec<u8>) -> Result<Self> {
        let bytes = Zeroizing::new(bytes);
        if bytes.len() > MAX_STATE || bytes.first() != Some(&SNAPSHOT_VERSION) {
            return Err(MlsError::InvalidInput);
        }
        let mut snapshot: Snapshot =
            postcard::from_bytes(&bytes[1..]).map_err(|_| MlsError::InvalidInput)?;
        if snapshot.identity.len() != 48 || snapshot.public_key.len() != 32 {
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
        let mut state = vec![SNAPSHOT_VERSION];
        state.extend(postcard::to_allocvec(&self.snapshot).map_err(|_| MlsError::InvalidState)?);
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
            added_writer: None,
            removed_writer: None,
            departed: None,
        })
    }

    fn discard_key_package(&self, bytes: &[u8]) -> Result<()> {
        let reference = protocol(openmls::ciphersuite::hash_ref::make_key_package_ref(
            bytes,
            SUITE,
            self.provider.crypto(),
        ))?;
        protocol(self.provider.storage().delete_key_package(&reference))
    }

    fn discard_key_packages(&mut self) -> Result<()> {
        for bytes in std::mem::take(&mut self.snapshot.key_package) {
            self.discard_key_package(&bytes)?;
        }
        Ok(())
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
    let writer_token = protocol(provider.rand().random_vec(32))?;
    let mut identity = device_id;
    identity.extend_from_slice(&Sha256::digest(&writer_token));
    let signer = protocol(SignatureKeyPair::new(SUITE.signature_algorithm()))?;
    protocol(signer.store(provider.storage()))?;
    let public_key = signer.to_public_vec();
    let fingerprint = key_fingerprint(&public_key);
    let client = Client {
        snapshot: Snapshot {
            identity,
            public_key,
            group_id: None,
            pending_commit: None,
            key_package: vec![],
            values: vec![],
        },
        provider,
        signer,
    };
    let transition = client.save(vec![], None, None, None, false)?;
    Ok(MlsIdentity {
        state: transition.state,
        fingerprint,
        writer_token,
    })
}

#[uniffi::export]
pub fn publish_key_package(state: Vec<u8>) -> Result<MlsTransition> {
    publish_with_lifetime(state, KEY_PACKAGE_LIFETIME)
}

fn publish_with_lifetime(state: Vec<u8>, lifetime: u64) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    if client.snapshot.group_id.is_some() {
        return Err(MlsError::InvalidState);
    }
    for bytes in std::mem::take(&mut client.snapshot.key_package) {
        let kp = KeyPackageIn::tls_deserialize_exact(&bytes).map_err(|_| MlsError::InvalidState)?;
        if kp
            .validate(client.provider.crypto(), ProtocolVersion::Mls10)
            .is_ok()
        {
            client.snapshot.key_package.push(bytes);
        } else {
            client.discard_key_package(&bytes)?;
        }
    }
    if client.snapshot.key_package.len() >= 8 {
        let oldest = client.snapshot.key_package.remove(0);
        client.discard_key_package(&oldest)?;
    }
    let bundle = protocol(
        KeyPackage::builder()
            .key_package_lifetime(Lifetime::new(lifetime))
            .build(SUITE, &client.provider, &client.signer, client.credential()),
    )?;
    let bytes = protocol(bundle.key_package().tls_serialize_detached())?;
    client.snapshot.key_package.push(bytes.clone());
    client.save(bytes, None, None, None, false)
}

#[uniffi::export]
pub fn create_group(state: Vec<u8>, group_id: Vec<u8>) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    if client.snapshot.group_id.is_some() || group_id.len() != 32 {
        return Err(MlsError::InvalidState);
    }
    let group = protocol(MlsGroup::new_with_group_id(
        &client.provider,
        &client.signer,
        &config(),
        GroupId::from_slice(&group_id),
        client.credential(),
    ))?;
    client.discard_key_packages()?;
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
    let (device_id, writer_hash) = credential_identity(kp.leaf_node().credential())?;
    verify_key(
        kp.leaf_node().signature_key().as_slice(),
        &verified_fingerprint,
    )?;
    let mut group = client.group()?;
    let departing = departing_fingerprints(&group);
    let current: Vec<_> = roster(&group)?
        .into_iter()
        .filter(|m| !departing.contains(&m.fingerprint))
        .collect();
    if current.len() >= 8
        || current.iter().any(|m| {
            m.fingerprint == verified_fingerprint
                || m.device_id == device_id
                || m.writer_hash == writer_hash
        })
    {
        return Err(MlsError::InvalidState);
    }
    let (commit, welcome, _) =
        protocol(group.add_members(&client.provider, &client.signer, &[kp]))?;
    let commit = encode(&commit)?;
    client.snapshot.pending_commit = Some(commit.clone());
    let mut transition = client.save(commit, Some(encode(&welcome)?), Some(&group), None, false)?;
    transition.added_writer = Some(writer_hash);
    Ok(transition)
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
    let (_, writer_hash) = credential_identity(&member.credential)?;
    let (commit, _, _) =
        protocol(group.remove_members(&client.provider, &client.signer, &[member.index]))?;
    let commit = encode(&commit)?;
    client.snapshot.pending_commit = Some(commit.clone());
    let mut transition = client.save(commit, None, Some(&group), None, false)?;
    transition.removed_writer = Some(writer_hash);
    Ok(transition)
}

#[uniffi::export]
pub fn prepare_leave(state: Vec<u8>) -> Result<MlsTransition> {
    let client = Client::load(state)?;
    client.ready()?;
    let mut group = client.group()?;
    let proposal = protocol(group.leave_group(&client.provider, &client.signer))?;
    client.save(encode(&proposal)?, None, Some(&group), None, false)
}

#[uniffi::export]
pub fn accept_commit(state: Vec<u8>, accepted_commit: Vec<u8>) -> Result<MlsTransition> {
    let mut client = Client::load(state)?;
    if client.snapshot.pending_commit.as_ref() != Some(&accepted_commit) {
        return Err(MlsError::InvalidState);
    }
    let mut group = client.group()?;
    protocol(group.merge_pending_commit(&client.provider))?;
    roster(&group)?;
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
    roster(&group)?;
    if group.group_id().as_slice() != expected_group_id {
        return Err(MlsError::InvalidInput);
    }
    client.snapshot.group_id = Some(expected_group_id);
    client.discard_key_packages()?;
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
    let sender = processed.sender().clone();
    match processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(message) => {
            let Sender::Member(index) = sender else {
                return Err(MlsError::InvalidInput);
            };
            let sender = key_fingerprint(
                &group
                    .members()
                    .find(|m| m.index == index)
                    .ok_or(MlsError::InvalidInput)?
                    .signature_key,
            );
            client.save(
                message.into_bytes(),
                None,
                Some(&group),
                Some(sender),
                false,
            )
        }
        ProcessedMessageContent::StagedCommitMessage(commit) => {
            if commit.queued_proposals().any(|queued| {
                !matches!(
                    queued.proposal(),
                    Proposal::Add(_) | Proposal::Remove(_) | Proposal::Update(_)
                )
            }) {
                return Err(MlsError::InvalidInput);
            }
            let removed_indices: HashSet<_> = commit
                .remove_proposals()
                .map(|proposal| proposal.remove_proposal().removed())
                .collect();
            let retained: Vec<_> = group
                .members()
                .filter(|member| !removed_indices.contains(&member.index))
                .map(|member| (member.index, member.credential))
                .collect();
            let removed = commit.self_removed();
            protocol(group.merge_staged_commit(&client.provider, *commit))?;
            roster(&group)?;
            for member in group.members() {
                if retained.iter().any(|(index, credential)| {
                    *index == member.index && *credential != member.credential
                }) {
                    return Err(MlsError::InvalidInput);
                }
            }
            client.snapshot.pending_commit = None;
            client.save(vec![], None, Some(&group), None, removed)
        }
        ProcessedMessageContent::ProposalMessage(queued) => {
            let Sender::Member(index) = sender else {
                return Err(MlsError::InvalidInput);
            };
            if index == group.own_leaf_index()
                || !matches!(queued.proposal(), Proposal::Remove(remove) if remove.removed() == index)
            {
                return Err(MlsError::InvalidInput);
            }
            let departed = key_fingerprint(
                &group
                    .members()
                    .find(|m| m.index == index)
                    .ok_or(MlsError::InvalidInput)?
                    .signature_key,
            );
            protocol(group.store_pending_proposal(client.provider.storage(), *queued))?;
            let mut transition = client.save(vec![], None, Some(&group), None, false)?;
            transition.departed = Some(departed);
            Ok(transition)
        }
        _ => Err(MlsError::InvalidInput),
    }
}

#[cfg(test)]
mod policy_tests {
    use super::*;

    fn has_package(client: &Client, bytes: &[u8]) -> bool {
        let reference = openmls::ciphersuite::hash_ref::make_key_package_ref(
            bytes,
            SUITE,
            client.provider.crypto(),
        )
        .unwrap();
        client
            .provider
            .storage()
            .key_package::<_, KeyPackageBundle>(&reference)
            .unwrap()
            .is_some()
    }

    #[test]
    fn publication_discards_expired_packages_and_retains_valid_packages() {
        let identity = create_identity(vec![2; 16]).unwrap();
        assert!(
            Client::load(identity.state.clone())
                .unwrap()
                .snapshot
                .key_package
                .is_empty()
        );
        let short = publish_with_lifetime(identity.state, 2).unwrap();
        let valid = publish_key_package(short.state).unwrap();
        let host = create_identity(vec![1; 16]).unwrap();
        let group = create_group(host.state, vec![7; 32]).unwrap();
        std::thread::sleep(std::time::Duration::from_secs(2));
        let error = prepare_add(
            group.state.clone(),
            short.output.clone(),
            identity.fingerprint.clone(),
        )
        .err()
        .unwrap();
        assert!(matches!(error, MlsError::LibraryRejected { ref code } if !code.is_empty()));
        let fresh = publish_key_package(valid.state).unwrap();
        let client = Client::load(fresh.state).unwrap();
        assert_eq!(
            client.snapshot.key_package,
            vec![valid.output.clone(), fresh.output]
        );
        assert!(!has_package(&client, &short.output));
        assert!(has_package(&client, &valid.output));
        assert!(prepare_add(group.state, valid.output, identity.fingerprint).is_ok());
    }

    #[test]
    fn create_and_join_discard_all_published_private_material() {
        let identity = create_identity(vec![2; 16]).unwrap();
        let first = publish_key_package(identity.state).unwrap();
        let second = publish_key_package(first.state).unwrap();
        let created = create_group(second.state.clone(), vec![8; 32]).unwrap();
        let host = create_identity(vec![1; 16]).unwrap();
        let group = create_group(host.state, vec![7; 32]).unwrap();
        let pending = prepare_add(group.state, first.output.clone(), identity.fingerprint).unwrap();
        let joined = join_group(
            second.state,
            pending.welcome.unwrap(),
            vec![7; 32],
            host.fingerprint,
        )
        .unwrap();
        for state in [created.state, joined.state] {
            let client = Client::load(state).unwrap();
            assert!(client.snapshot.key_package.is_empty());
            assert!(!has_package(&client, &first.output));
            assert!(!has_package(&client, &second.output));
        }
    }

    #[test]
    fn publication_drops_oldest_package_at_capacity() {
        let mut state = create_identity(vec![2; 16]).unwrap().state;
        let mut packages = Vec::new();
        for _ in 0..9 {
            let published = publish_key_package(state).unwrap();
            packages.push(published.output);
            state = published.state;
        }
        let client = Client::load(state).unwrap();
        assert_eq!(client.snapshot.key_package, packages[1..]);
        assert!(!has_package(&client, &packages[0]));
        assert!(
            packages[1..]
                .iter()
                .all(|bytes| has_package(&client, bytes))
        );
    }

    #[test]
    fn library_error_text_is_truncated_to_200_characters() {
        let error = protocol::<(), _>(Err("é".repeat(201))).unwrap_err();
        assert!(matches!(error, MlsError::LibraryRejected { code } if code.chars().count() == 200));
    }

    fn unchecked_add(state: Vec<u8>, key_package: Vec<u8>) -> (Vec<u8>, Vec<u8>) {
        let client = Client::load(state).unwrap();
        let mut group = client.group().unwrap();
        let kp = KeyPackageIn::tls_deserialize_exact(key_package)
            .unwrap()
            .validate(client.provider.crypto(), ProtocolVersion::Mls10)
            .unwrap();
        let (commit, _, _) = group
            .add_members(&client.provider, &client.signer, &[kp])
            .unwrap();
        group.merge_pending_commit(&client.provider).unwrap();
        let transition = client
            .save(encode(&commit).unwrap(), None, Some(&group), None, false)
            .unwrap();
        (transition.state, transition.output)
    }

    #[test]
    fn proposals_other_than_self_removal_are_rejected() {
        let alice = create_identity(vec![1; 16]).unwrap();
        let bob = create_identity(vec![2; 16]).unwrap();
        let charlie = create_identity(vec![3; 16]).unwrap();
        let group = create_group(alice.state, vec![7; 32]).unwrap();
        let bob_package = publish_key_package(bob.state).unwrap();
        let pending = prepare_add(group.state, bob_package.output, bob.fingerprint).unwrap();
        let b = join_group(
            bob_package.state,
            pending.welcome.unwrap(),
            vec![7; 32],
            alice.fingerprint.clone(),
        )
        .unwrap()
        .state;
        let a = accept_commit(pending.state, pending.output).unwrap().state;
        let charlie_package = publish_key_package(charlie.state).unwrap();
        let pending = prepare_add(a, charlie_package.output, charlie.fingerprint).unwrap();
        let b = receive_message(b, pending.output.clone()).unwrap().state;
        let a = accept_commit(pending.state, pending.output).unwrap().state;
        let client = Client::load(a).unwrap();
        let mut group = client.group().unwrap();
        let victim = group
            .members()
            .find(|m| {
                m.index != group.own_leaf_index()
                    && key_fingerprint(&m.signature_key) != alice.fingerprint
            })
            .unwrap()
            .index;
        let (proposal, _) = group
            .propose_remove_member(&client.provider, &client.signer, victim)
            .unwrap();
        assert!(matches!(
            receive_message(b, encode(&proposal).unwrap()),
            Err(MlsError::InvalidInput)
        ));
    }

    #[test]
    fn received_duplicate_identity_and_ninth_member_are_rejected() {
        let alice = create_identity(vec![1; 16]).unwrap();
        let bob = create_identity(vec![2; 16]).unwrap();
        let group = create_group(alice.state, vec![7; 32]).unwrap();
        let published = publish_key_package(bob.state).unwrap();
        let pending = prepare_add(group.state, published.output, bob.fingerprint).unwrap();
        let mut receiver = join_group(
            published.state,
            pending.welcome.unwrap(),
            vec![7; 32],
            alice.fingerprint,
        )
        .unwrap()
        .state;
        let mut sender = accept_commit(pending.state, pending.output).unwrap().state;
        let mut attacker = Client::load(sender.clone()).unwrap();
        attacker.snapshot.identity[0] ^= 0xff;
        let mut changed = attacker.group().unwrap();
        let update = changed
            .self_update(
                &attacker.provider,
                &attacker.signer,
                LeafNodeParameters::builder()
                    .with_credential_with_key(attacker.credential())
                    .build(),
            )
            .unwrap();
        assert!(matches!(
            receive_message(receiver.clone(), encode(update.commit()).unwrap()),
            Err(MlsError::InvalidInput)
        ));
        let duplicate = create_identity(vec![2; 16]).unwrap();
        let (_, invalid) = unchecked_add(
            sender.clone(),
            publish_key_package(duplicate.state).unwrap().output,
        );
        assert!(matches!(
            receive_message(receiver.clone(), invalid),
            Err(MlsError::InvalidInput)
        ));
        for id in 3..=8 {
            let joiner = create_identity(vec![id; 16]).unwrap();
            let (next, commit) =
                unchecked_add(sender, publish_key_package(joiner.state).unwrap().output);
            receiver = receive_message(receiver, commit).unwrap().state;
            sender = next;
        }
        assert_eq!(members(receiver.clone()).unwrap().len(), 8);
        let ninth = create_identity(vec![9; 16]).unwrap();
        let (_, invalid) = unchecked_add(sender, publish_key_package(ninth.state).unwrap().output);
        assert!(matches!(
            receive_message(receiver, invalid),
            Err(MlsError::InvalidInput)
        ));
    }
}
