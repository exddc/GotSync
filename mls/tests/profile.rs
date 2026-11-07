use gotsync_mls::*;

const GROUP: [u8; 32] = [7; 32];

fn profile(application: &str, schema: &str, version: u16, limit: u8) -> Vec<u8> {
    let mut bytes = vec![1, application.len() as u8];
    bytes.extend_from_slice(application.as_bytes());
    bytes.push(schema.len() as u8);
    bytes.extend_from_slice(schema.as_bytes());
    bytes.extend_from_slice(&version.to_be_bytes());
    bytes.push(limit);
    bytes
}

fn ten() -> Vec<u8> {
    profile("com.example.tasks", "gotsync.task-replica", 2, 10)
}

struct Identity {
    state: Vec<u8>,
    key_package: Vec<u8>,
    fingerprint: Vec<u8>,
}

fn identity(id: u8, profile: Option<Vec<u8>>) -> Identity {
    let identity = create_identity(vec![id; 16]).unwrap();
    let published = publish_key_package(identity.state, profile).unwrap();
    Identity {
        state: published.state,
        key_package: published.output,
        fingerprint: identity.fingerprint,
    }
}

/// Grows a group created by member 1 to `size` members and returns every
/// member's state, inviter first.
fn grow(profile: Option<Vec<u8>>, size: u8) -> (Vec<Vec<u8>>, Identity) {
    let alice = identity(1, profile.clone());
    let mut states = vec![
        create_group(alice.state.clone(), GROUP.to_vec(), profile.clone())
            .unwrap()
            .state,
    ];
    for id in 2..=size {
        let joiner = identity(id, profile.clone());
        let pending = prepare_add(
            states[0].clone(),
            joiner.key_package.clone(),
            joiner.fingerprint.clone(),
        )
        .unwrap();
        let joined = join_group(
            joiner.state,
            pending.welcome.clone().unwrap(),
            GROUP.to_vec(),
            alice.fingerprint.clone(),
            profile.clone(),
        )
        .unwrap();
        for state in states.iter_mut().skip(1) {
            *state = receive_message(state.clone(), pending.output.clone())
                .unwrap()
                .state;
        }
        states[0] = accept_commit(pending.state, pending.output).unwrap().state;
        states.push(joined.state);
    }
    (states, alice)
}

#[test]
fn shared_descriptor_vector_matches_the_swift_encoding() {
    let hex: String = ten().iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        hex,
        "0111636f6d2e6578616d706c652e7461736b7314676f7473796e632e7461736b2d7265706c69636100020a"
    );
    assert_eq!(supported_member_ceiling(), 10);
}

#[test]
fn profiled_group_admits_ten_members_and_refuses_an_eleventh() {
    let (states, _) = grow(Some(ten()), 10);
    for state in &states {
        assert_eq!(members(state.clone()).unwrap().len(), 10);
        assert_eq!(group_profile(state.clone()).unwrap(), Some(ten()));
    }
    let eleventh = identity(11, Some(ten()));
    assert!(matches!(
        prepare_add(
            states[3].clone(),
            eleventh.key_package,
            eleventh.fingerprint
        ),
        Err(MlsError::InvalidState)
    ));
    let sent = seal_message(states[9].clone(), b"tenth member".to_vec()).unwrap();
    for state in &states[..9] {
        assert_eq!(
            receive_message(state.clone(), sent.output.clone())
                .unwrap()
                .output,
            b"tenth member"
        );
    }
}

#[test]
fn removal_frees_a_slot_and_the_profile_survives_commits_and_reload() {
    let (mut states, _) = grow(Some(ten()), 10);
    let removed = members(states[0].clone()).unwrap()[4].fingerprint.clone();
    let pending = prepare_remove(states[2].clone(), removed).unwrap();
    for (index, state) in states.iter_mut().enumerate() {
        if index != 2 {
            *state = receive_message(state.clone(), pending.output.clone())
                .unwrap()
                .state;
        }
    }
    states[2] = accept_commit(pending.state, pending.output).unwrap().state;
    states.remove(4);
    let replacement = identity(12, Some(ten()));
    let pending = prepare_add(
        states[0].clone(),
        replacement.key_package,
        replacement.fingerprint,
    )
    .unwrap();
    let a = accept_commit(pending.state, pending.output).unwrap().state;
    assert_eq!(members(a.clone()).unwrap().len(), 10);
    let reloaded = seal_message(a, b"after replacement".to_vec()).unwrap();
    assert_eq!(group_profile(reloaded.state).unwrap(), Some(ten()));
}

#[test]
fn legacy_group_keeps_eight_members_and_reports_no_profile() {
    let (states, _) = grow(None, 8);
    assert_eq!(group_profile(states[0].clone()).unwrap(), None);
    let ninth = identity(9, None);
    assert!(matches!(
        prepare_add(states[0].clone(), ninth.key_package, ninth.fingerprint),
        Err(MlsError::InvalidState)
    ));
}

#[test]
fn smaller_profiled_limit_is_enforced() {
    let three = profile("com.example.tasks", "gotsync.task-replica", 2, 3);
    let (states, _) = grow(Some(three), 3);
    let fourth = identity(4, Some(ten()));
    assert!(matches!(
        prepare_add(states[1].clone(), fourth.key_package, fourth.fingerprint),
        Err(MlsError::InvalidState)
    ));
}

#[test]
fn legacy_key_package_cannot_be_added_to_a_profiled_group() {
    let (states, _) = grow(Some(ten()), 2);
    let legacy = identity(3, None);
    assert!(matches!(
        prepare_add(states[0].clone(), legacy.key_package, legacy.fingerprint),
        Err(MlsError::LibraryRejected { .. })
    ));
}

#[test]
fn welcome_with_a_different_profile_is_refused_before_joining() {
    let other_schema = profile("com.example.tasks", "com.example.records", 1, 10);
    let other_application = profile("com.example.other", "gotsync.task-replica", 2, 10);
    let other_limit = profile("com.example.tasks", "gotsync.task-replica", 2, 9);
    let other_version = profile("com.example.tasks", "gotsync.task-replica", 3, 10);
    let cases: [(Option<Vec<u8>>, Option<Vec<u8>>); 6] = [
        (Some(ten()), None),
        (None, Some(ten())),
        (Some(ten()), Some(other_schema)),
        (Some(ten()), Some(other_application)),
        (Some(ten()), Some(other_limit)),
        (Some(ten()), Some(other_version)),
    ];
    for (group_profile_bytes, expected) in cases {
        let alice = identity(1, group_profile_bytes.clone());
        let bob = identity(2, Some(ten()));
        let created =
            create_group(alice.state, GROUP.to_vec(), group_profile_bytes.clone()).unwrap();
        let pending = prepare_add(created.state, bob.key_package, bob.fingerprint).unwrap();
        assert!(matches!(
            join_group(
                bob.state.clone(),
                pending.welcome.unwrap(),
                GROUP.to_vec(),
                alice.fingerprint,
                expected,
            ),
            Err(MlsError::ProfileMismatch)
        ));
        assert!(matches!(
            group_profile(bob.state),
            Err(MlsError::InvalidState)
        ));
    }
}

#[test]
fn malformed_descriptors_are_refused_everywhere() {
    let valid = ten();
    let mut trailing = valid.clone();
    trailing.push(0);
    let mut truncated = valid.clone();
    truncated.pop();
    let mut wrong_format = valid.clone();
    wrong_format[0] = 2;
    let cases = [
        vec![],
        trailing,
        truncated,
        wrong_format,
        profile("com.example.tasks", "gotsync.task-replica", 2, 11),
        profile("com.example.tasks", "gotsync.task-replica", 2, 1),
        profile("com.example.tasks", "gotsync.task-replica", 0, 10),
        profile("Com.example", "gotsync.task-replica", 2, 10),
        profile("", "gotsync.task-replica", 2, 10),
        profile(".example", "gotsync.task-replica", 2, 10),
        profile("com.example.tasks", "gotsync task", 2, 10),
        profile(&"a".repeat(65), "gotsync.task-replica", 2, 10),
    ];
    for bytes in cases {
        let id = create_identity(vec![1; 16]).unwrap();
        assert!(matches!(
            create_group(id.state.clone(), GROUP.to_vec(), Some(bytes.clone())),
            Err(MlsError::InvalidInput)
        ));
        assert!(matches!(
            publish_key_package(id.state.clone(), Some(bytes.clone())),
            Err(MlsError::InvalidInput)
        ));
        assert!(matches!(
            join_group(id.state, vec![1], GROUP.to_vec(), vec![0; 32], Some(bytes)),
            Err(MlsError::InvalidInput)
        ));
    }
    let longest = profile(&"a".repeat(64), &"b".repeat(64), u16::MAX, 2);
    let id = create_identity(vec![1; 16]).unwrap();
    let created = create_group(id.state, GROUP.to_vec(), Some(longest.clone())).unwrap();
    assert_eq!(group_profile(created.state).unwrap(), Some(longest));
}
