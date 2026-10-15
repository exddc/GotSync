use mls_rs::{
    client_builder::MlsConfig,
    identity::{
        basic::{BasicCredential, BasicIdentityProvider},
        SigningIdentity,
    },
    CipherSuite, CipherSuiteProvider, Client, CryptoProvider,
};
use mls_rs_crypto_rustcrypto::RustCryptoProvider;

fn client(name: &[u8]) -> Client<impl MlsConfig> {
    let provider = RustCryptoProvider::default();
    let suite = CipherSuite::CURVE25519_AES128;
    let (secret, public) = provider
        .cipher_suite_provider(suite)
        .unwrap()
        .signature_key_generate()
        .unwrap();
    Client::builder()
        .identity_provider(BasicIdentityProvider)
        .crypto_provider(provider)
        .signing_identity(
            SigningIdentity::new(
                BasicCredential::new(name.to_vec()).into_credential(),
                public,
            ),
            secret,
            suite,
        )
        .build()
}

pub fn pair_and_encrypt() {
    let alice = client(b"alice");
    let bob = client(b"bob");
    let mut group = alice.group_builder().unwrap().build().unwrap();
    let kp = bob
        .generate_key_package_message(Default::default(), Default::default(), None)
        .unwrap();
    let commit = group
        .commit_builder()
        .add_member(kp)
        .unwrap()
        .build()
        .unwrap();
    group.apply_pending_commit().unwrap();
    let (mut joined, _) = bob
        .join_group(None, &commit.welcome_messages[0], None)
        .unwrap();
    let message = group
        .encrypt_application_message(b"comparison", Default::default())
        .unwrap();
    joined.process_incoming_message(message).unwrap();
}

#[test]
fn pair_and_sync() {
    pair_and_encrypt();
}
