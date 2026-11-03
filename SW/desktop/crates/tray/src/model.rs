//! State presentation only; authentication and enrollment stay in core.
use anyhow::Result;
use serde::Serialize;
use voiceremote_core::{
    pairing::{Clock, Offer},
    protocol::{self, Mode},
    storage::Identity,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Icon {
    Unknown,
    DictationOff,
    DictationListening,
    AiOff,
    AiListening,
    Selected,
}
pub fn icon(status: &crate::control::Status, flash: bool) -> Icon {
    if flash {
        return Icon::Selected;
    }
    if !status.connected {
        return Icon::Unknown;
    }
    match (&status.mode, status.listening) {
        (Some(Mode::Dictation), Some(false)) => Icon::DictationOff,
        (Some(Mode::Dictation), Some(true)) => Icon::DictationListening,
        (Some(Mode::AiControl), Some(false)) => Icon::AiOff,
        (Some(Mode::AiControl), Some(true)) => Icon::AiListening,
        _ => Icon::Unknown,
    }
}
/// D/A glyph plus listening dot; distinct shapes and colors, not color alone.
pub fn icon_rgba(icon: Icon) -> Vec<u8> {
    let mut pixels = vec![0; 32 * 32 * 4];
    let color = match icon {
        Icon::Selected => [255, 190, 40, 255],
        Icon::DictationListening | Icon::AiListening => [30, 210, 130, 255],
        _ => [155, 170, 190, 255],
    };
    let ai = matches!(icon, Icon::AiOff | Icon::AiListening);
    for y in 5..27 {
        for x in 5..27 {
            let glyph = if ai {
                (x == 7 || x == 23) || (y == 6 || y == 16)
            } else {
                x == 7 || ((y == 6 || y == 25) && x < 22) || (x == 23 && y > 8 && y < 23)
            };
            let dot = matches!(
                icon,
                Icon::DictationListening | Icon::AiListening | Icon::Selected
            ) && (24..29).contains(&x)
                && (24..29).contains(&y);
            if glyph || dot {
                let i = (y * 32 + x) * 4;
                pixels[i..i + 4].copy_from_slice(&color);
            }
        }
    }
    pixels
}
#[derive(Clone, Serialize)]
pub struct QrView {
    pub svg: String,
    pub invitation: String,
    pub expires_at: u64,
}
pub struct RotatingOffer {
    pub offer: Offer,
    view: QrView,
}
impl RotatingOffer {
    pub fn new(
        identity: &Identity,
        account: String,
        room: String,
        clock: &dyn Clock,
    ) -> Result<Self> {
        Self::from_offer(Offer::issue(identity, account, room, clock)?)
    }
    pub fn from_offer(offer: Offer) -> Result<Self> {
        let payload = protocol::encode(&offer.payload).map_err(anyhow::Error::msg)?;
        let invitation = payload.clone();
        let svg = qrcode::QrCode::new(payload.as_bytes())?
            .render::<qrcode::render::svg::Color>()
            .min_dimensions(300, 300)
            .quiet_zone(true)
            .build();
        let view = QrView {
            svg,
            invitation,
            expires_at: offer.payload.expires_at,
        };
        Ok(Self { offer, view })
    }
    pub fn view(&self) -> QrView {
        self.view.clone()
    }
    pub fn expired(&self, clock: &dyn Clock) -> Result<bool> {
        Ok(clock.now_ms()? >= self.view.expires_at)
    }
    pub fn rotate(&mut self, identity: &Identity, clock: &dyn Clock) -> Result<bool> {
        if !self.expired(clock)? {
            return Ok(false);
        }
        *self = Self::new(
            identity,
            self.offer.payload.account_id.clone(),
            self.offer.payload.relay_room_id.clone(),
            clock,
        )?;
        Ok(true)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use voiceremote_core::{pairing::TOKEN_TTL_MS, protocol::CaptureState};
    struct Time(u64);
    impl Clock for Time {
        fn now_ms(&self) -> Result<u64> {
            Ok(self.0)
        }
    }
    #[test]
    fn qr_rotation_changes_token_at_expiry_and_preserves_identity() -> Result<()> {
        let identity = Identity::generate()?;
        let mut qr = RotatingOffer::new(&identity, "test".into(), "room".into(), &Time(1))?;
        let original = protocol::encode(&qr.offer.payload).unwrap();
        let old_code = qr.view.invitation.clone();
        assert_eq!(
            protocol::decode::<voiceremote_core::protocol::PairingPayload>(&old_code)
                .map_err(anyhow::Error::msg)?,
            qr.offer.payload
        );
        assert!(!qr.rotate(&identity, &Time(TOKEN_TTL_MS))?);
        assert_eq!(protocol::encode(&qr.offer.payload).unwrap(), original);
        assert!(qr.rotate(&identity, &Time(TOKEN_TTL_MS + 1))?);
        assert_ne!(protocol::encode(&qr.offer.payload).unwrap(), original);
        assert_ne!(qr.view.invitation, old_code);
        assert_eq!(qr.offer.payload.expires_at, TOKEN_TTL_MS * 2 + 1);
        Ok(())
    }
    #[test]
    fn every_mode_and_capture_state_has_a_distinct_state_icon() {
        let mut status = crate::control::Status::default();
        assert_eq!(icon(&status, false), Icon::Unknown);
        status.connected = true;
        for (mode, off, on) in [
            (
                Mode::Dictation,
                Icon::DictationOff,
                Icon::DictationListening,
            ),
            (Mode::AiControl, Icon::AiOff, Icon::AiListening),
        ] {
            status.mode = Some(mode);
            for capture in [
                CaptureState::Off,
                CaptureState::Hold,
                CaptureState::Continuous,
            ] {
                let expected = if capture == CaptureState::Off {
                    off
                } else {
                    on
                };
                status.listening = Some(capture != CaptureState::Off);
                status.capture = Some(capture);
                assert_eq!(icon(&status, false), expected);
            }
        }
        assert_eq!(icon(&status, true), Icon::Selected);
        assert_ne!(icon_rgba(Icon::AiOff), icon_rgba(Icon::DictationOff));
        assert_ne!(icon_rgba(Icon::AiOff), icon_rgba(Icon::AiListening));
    }
}
