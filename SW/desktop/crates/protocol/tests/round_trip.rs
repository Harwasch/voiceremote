use serde::Deserialize;
use serde_json::Value;
use voiceremote_protocol::*;

#[derive(Deserialize)]
struct Vector {
    name: String,
    schema: String,
    value: Value,
    json: Option<String>,
}
#[derive(Deserialize)]
struct RawVector {
    name: String,
    schema: String,
    json: String,
}
#[derive(Deserialize)]
struct Vectors {
    valid: Vec<Vector>,
    invalid: Vec<Vector>,
    raw_invalid: Vec<RawVector>,
}

fn vectors() -> Vectors {
    serde_json::from_str(include_str!(
        "../../../../../SYS/protocol/vectors/golden.json"
    ))
    .unwrap()
}
fn typed_round_trip<T: WireRecord>(json: &str) -> Result<Value, String> {
    let decoded = decode::<T>(json)?;
    let encoded = encode(&decoded)?;
    // Decode again to ensure emitted values remain admissible.
    decode::<T>(&encoded)?;
    serde_json::from_str(&encoded).map_err(|e| e.to_string())
}
fn typed(name: &str, json: &str) -> Result<Value, String> {
    match name {
        "AuditArchiveWriter" => typed_round_trip::<AuditArchiveWriter>(json),
        "AuditArchiveBlock" => typed_round_trip::<AuditArchiveBlock>(json),
        "AuditArchiveRead" => typed_round_trip::<AuditArchiveRead>(json),
        "AuditArchivePage" => typed_round_trip::<AuditArchivePage>(json),
        "RelayFrame" => typed_round_trip::<RelayFrame>(json),
        "RelayCiphertext" => typed_round_trip::<RelayCiphertext>(json),
        "RelayPresence" => typed_round_trip::<RelayPresence>(json),
        "RelayWakeRegistration" => typed_round_trip::<RelayWakeRegistration>(json),
        "PairingPayload" => typed_round_trip::<PairingPayload>(json),
        "InnerMessage" => typed_round_trip::<InnerMessage>(json),
        "DictationText" => typed_round_trip::<DictationText>(json),
        "FocusReport" => typed_round_trip::<FocusReport>(json),
        "DeviceInfo" => typed_round_trip::<DeviceInfo>(json),
        "Revoke" => typed_round_trip::<Revoke>(json),
        "TaskStatus" => typed_round_trip::<TaskStatus>(json),
        "CaptureSegment" => typed_round_trip::<CaptureSegment>(json),
        "CandidateAction" => typed_round_trip::<CandidateAction>(json),
        "AuthorizedCommand" => typed_round_trip::<AuthorizedCommand>(json),
        "AuditEntry" => typed_round_trip::<AuditEntry>(json),
        "Grant" => typed_round_trip::<Grant>(json),
        "ModeState" => typed_round_trip::<ModeState>(json),
        "CaptureStateReport" => typed_round_trip::<CaptureStateReport>(json),
        "TargetPrepare" => typed_round_trip::<TargetPrepare>(json),
        "TargetReady" => typed_round_trip::<TargetReady>(json),
        "DictationOutcome" => typed_round_trip::<DictationOutcome>(json),
        "DictationQuery" => typed_round_trip::<DictationQuery>(json),
        "CaptureControl" => typed_round_trip::<CaptureControl>(json),
        "CaptureControlResult" => typed_round_trip::<CaptureControlResult>(json),
        "AgentSession" => typed_round_trip::<AgentSession>(json),
        "AgentInventoryRequest" => typed_round_trip::<AgentInventoryRequest>(json),
        "AgentInventory" => typed_round_trip::<AgentInventory>(json),
        "AgentDispatch" => typed_round_trip::<AgentDispatch>(json),
        "AgentTaskQuery" => typed_round_trip::<AgentTaskQuery>(json),
        "ToolCall" => typed_round_trip::<ToolCall>(json),
        "SelectTargetTool" => typed_round_trip::<SelectTargetTool>(json),
        "OpenResourceTool" => typed_round_trip::<OpenResourceTool>(json),
        "DelegateTaskTool" => typed_round_trip::<DelegateTaskTool>(json),
        "CancelTaskTool" => typed_round_trip::<CancelTaskTool>(json),
        "PrepareSendTool" => typed_round_trip::<PrepareSendTool>(json),
        _ => Err(format!("Missing typed coverage: {name}")),
    }
}
fn equivalent(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(a, b)| equivalent(a, b))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, a)| y.get(k).is_some_and(|b| equivalent(a, b)))
        }
        _ => a == b,
    }
}

#[test]
fn shared_golden_records_round_trip_through_real_types() {
    let vectors = vectors();
    for v in &vectors.valid {
        validate(&v.schema, &v.value).unwrap_or_else(|e| panic!("{}: {e}", v.name));
        let json = v.json.clone().unwrap_or_else(|| v.value.to_string());
        let output = typed(&v.schema, &json).unwrap_or_else(|e| panic!("{}: {e}", v.name));
        assert!(
            equivalent(&output, &v.value),
            "{} lost or changed data",
            v.name
        );
    }
    println!("{} shared valid vectors round-tripped", vectors.valid.len());
}

#[test]
fn shared_invalid_vectors_are_rejected() {
    let vectors = vectors();
    for v in &vectors.invalid {
        assert!(
            validate(&v.schema, &v.value).is_err(),
            "Accepted {}",
            v.name
        );
        assert!(
            typed(&v.schema, &v.value.to_string()).is_err(),
            "Typed codec accepted {}",
            v.name
        );
    }
    println!("{} shared invalid vectors rejected", vectors.invalid.len());
}

#[test]
fn shared_raw_invalid_vectors_are_rejected() {
    let fixtures = vectors();
    for v in &fixtures.raw_invalid {
        assert!(
            typed(&v.schema, &v.json).is_err(),
            "Typed codec accepted {}",
            v.name
        );
    }
    println!(
        "{} shared raw invalid vectors rejected",
        fixtures.raw_invalid.len()
    );
}

#[test]
fn constructed_values_are_validated_when_encoded() {
    let mut message = decode::<DictationText>(r#"{"kind":"dictation_text","account_id":"fixture-account","segment_id":"segment-1","revision":0,"state":"committed","target_device_id":"fixture-desktop","text":"SYNTHETIC"}"#).unwrap();
    message.text = "SYNTHETIC\n".into();
    assert!(encode(&message).is_err());
    assert!(decode::<InnerMessage>(r#"{"kind":"unknown"}"#).is_err());
    assert!(decode::<RelayFrame>("not JSON").is_err());
}
