use gotsync_mls::*;

struct Identity {
    state: Vec<u8>,
    key_package: Vec<u8>,
    fingerprint: Vec<u8>,
}
fn identity(id: u8) -> Identity {
    let identity = create_identity(vec![id; 16]).unwrap();
    let published = publish_key_package(identity.state).unwrap();
    Identity {
        state: published.state,
        key_package: published.output,
        fingerprint: identity.fingerprint,
    }
}
fn group(id: &Identity) -> MlsTransition {
    create_group(id.state.clone(), vec![7; 32]).unwrap()
}
fn add(host: Vec<u8>, joiner: &Identity, inviter: &Identity) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let pending =
        prepare_add(host, joiner.key_package.clone(), joiner.fingerprint.clone()).unwrap();
    let joined = join_group(
        joiner.state.clone(),
        pending.welcome.unwrap(),
        vec![7; 32],
        inviter.fingerprint.clone(),
    )
    .unwrap();
    let accepted = accept_commit(pending.state, pending.output.clone()).unwrap();
    (accepted.state, joined.state, pending.output)
}

#[test]
fn three_members_offline_catchup_and_removal() {
    let alice = identity(1);
    let bob = identity(2);
    let charlie = identity(3);
    let (a, b, _) = add(group(&alice).state, &bob, &alice);
    let (a, c, commit) = add(a, &charlie, &alice);
    let b = receive_message(b, commit).unwrap().state;
    let sent = seal_message(a, b"offline edit".to_vec()).unwrap();
    assert_eq!(
        receive_message(b.clone(), sent.output.clone())
            .unwrap()
            .output,
        b"offline edit"
    );
    let c = receive_message(c, sent.output).unwrap().state;
    let pending = prepare_remove(sent.state, bob.fingerprint).unwrap();
    let c = receive_message(c, pending.output.clone()).unwrap().state;
    let removed = receive_message(b.clone(), pending.output.clone()).unwrap();
    assert!(removed.removed);
    let a = accept_commit(pending.state, pending.output).unwrap().state;
    let next = seal_message(a, b"after removal".to_vec()).unwrap();
    assert!(receive_message(b, next.output.clone()).is_err());
    assert!(receive_message(removed.state, next.output.clone()).is_err());
    assert_eq!(
        receive_message(c, next.output).unwrap().output,
        b"after removal"
    );
}

#[test]
fn fingerprints_and_group_id_are_verified_in_both_directions() {
    let alice = identity(1);
    let bob = identity(2);
    let a = group(&alice).state;
    assert!(matches!(
        prepare_add(a.clone(), bob.key_package.clone(), vec![0; 32]),
        Err(MlsError::FingerprintMismatch)
    ));
    let pending = prepare_add(a, bob.key_package, bob.fingerprint).unwrap();
    let welcome = pending.welcome.unwrap();
    assert!(matches!(
        join_group(bob.state.clone(), welcome.clone(), vec![7; 32], vec![0; 32]),
        Err(MlsError::FingerprintMismatch)
    ));
    assert!(
        join_group(
            bob.state.clone(),
            welcome.clone(),
            vec![8; 32],
            alice.fingerprint.clone()
        )
        .is_err()
    );
    assert!(join_group(bob.state, welcome, vec![7; 32], alice.fingerprint).is_ok());
}

#[test]
fn pending_commit_survives_reload_and_can_be_discarded_for_winner() {
    let alice = identity(1);
    let bob = identity(2);
    let charlie = identity(3);
    let (a, b, _) = add(group(&alice).state, &bob, &alice);
    let loser = prepare_add(a, charlie.key_package.clone(), charlie.fingerprint.clone()).unwrap();
    assert!(seal_message(loser.state.clone(), b"blocked".to_vec()).is_err());
    assert!(accept_commit(loser.state.clone(), vec![0]).is_err());
    let winner = prepare_add(b, charlie.key_package, charlie.fingerprint).unwrap();
    let a = discard_commit(loser.state).unwrap().state;
    let a = receive_message(a, winner.output.clone()).unwrap().state;
    let b = accept_commit(winner.state, winner.output).unwrap().state;
    let sent = seal_message(a, b"converged".to_vec()).unwrap();
    assert_eq!(
        receive_message(b, sent.output).unwrap().output,
        b"converged"
    );
}

#[test]
fn replay_tampering_and_unknown_member_are_rejected() {
    let alice = identity(1);
    let bob = identity(2);
    let outsider = identity(3);
    let (a, b, _) = add(group(&alice).state, &bob, &alice);
    let message = seal_message(a, b"known sender".to_vec()).unwrap().output;
    let received = receive_message(b.clone(), message.clone()).unwrap();
    assert!(receive_message(received.state, message.clone()).is_err());
    let mut tampered = message;
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    assert!(receive_message(b.clone(), tampered).is_err());
    let other_group = create_group(outsider.state, vec![7; 32]).unwrap();
    let forged = seal_message(other_group.state, b"unknown sender".to_vec()).unwrap();
    assert!(receive_message(b, forged.output).is_err());
}

#[test]
fn welcome_must_be_signed_by_pinned_inviter_not_just_contain_them() {
    let inviter = identity(1);
    let joiner = identity(2);
    let attacker = identity(3);
    let malicious = group(&attacker);
    let pending = prepare_add(
        malicious.state,
        inviter.key_package,
        inviter.fingerprint.clone(),
    )
    .unwrap();
    let malicious = accept_commit(pending.state, pending.output).unwrap();
    let pending = prepare_add(malicious.state, joiner.key_package, joiner.fingerprint).unwrap();
    assert!(matches!(
        join_group(
            joiner.state,
            pending.welcome.unwrap(),
            vec![7; 32],
            inviter.fingerprint
        ),
        Err(MlsError::FingerprintMismatch)
    ));
}

#[test]
fn snapshot_version_and_reload_preserve_group_identity() {
    let identity = create_identity(vec![1; 16]).unwrap();
    assert_eq!(identity.state[0], 4);
    let mut old = identity.state.clone();
    old[0] = 3;
    assert!(matches!(
        create_group(old, vec![7; 32]),
        Err(MlsError::InvalidInput)
    ));
    let saved = create_group(identity.state, vec![7; 32]).unwrap();
    let roster = members(saved.state.clone()).unwrap();
    assert_eq!(roster[0].device_id, vec![1; 16]);
    assert_eq!(roster[0].fingerprint, identity.fingerprint);
    let message = seal_message(saved.state, b"round trip".to_vec()).unwrap();
    assert_eq!(
        members(message.state).unwrap()[0].fingerprint,
        roster[0].fingerprint
    );
}

#[test]
fn any_unexpired_published_package_can_join() {
    let alice = identity(1);
    let bob = identity(2);
    let fresh = publish_key_package(bob.state.clone()).unwrap();
    let old = prepare_add(
        group(&alice).state,
        bob.key_package,
        bob.fingerprint.clone(),
    )
    .unwrap();
    assert!(
        join_group(
            fresh.state.clone(),
            old.welcome.unwrap(),
            vec![7; 32],
            alice.fingerprint.clone()
        )
        .is_ok()
    );
    let pending = prepare_add(group(&alice).state, fresh.output, bob.fingerprint).unwrap();
    assert!(
        join_group(
            fresh.state,
            pending.welcome.unwrap(),
            vec![7; 32],
            alice.fingerprint
        )
        .is_ok()
    );
}
