#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tauri::{
    Manager, State,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
};
use tauri_plugin_autostart::ManagerExt;
use voiceremote_tray::{
    backend::{self, Backend, LogEvent, Settings, Snapshot},
    control, model,
};

fn failure(_: impl std::fmt::Display) -> String {
    "Operation unavailable; check the connection and try again".into()
}
#[tauri::command]
fn snapshot(backend: State<'_, Arc<Backend>>) -> Result<Snapshot, String> {
    backend.snapshot().map_err(failure)
}
#[tauri::command]
async fn pair(
    settings: Settings,
    provisioning_secret: Option<String>,
    backend: State<'_, Arc<Backend>>,
) -> Result<(), String> {
    backend
        .pair(settings, provisioning_secret)
        .map_err(failure)?;
    let _ = backend::log(&backend.root, LogEvent::PairRequested);
    Ok(())
}
#[tauri::command]
fn confirm(phrase: String, backend: State<'_, Arc<Backend>>) -> Result<(), String> {
    backend.confirm(phrase).map_err(failure)?;
    let _ = backend::log(&backend.root, LogEvent::Confirmed);
    Ok(())
}
#[tauri::command]
fn cancel(backend: State<'_, Arc<Backend>>) {
    backend.cancel();
}
#[tauri::command]
async fn revoke(id: String, backend: State<'_, Arc<Backend>>) -> Result<(), String> {
    backend.revoke(&id).await.map_err(failure)?;
    let _ = backend::log(&backend.root, LogEvent::Revoked);
    Ok(())
}
#[tauri::command]
async fn toggle() -> Result<(), String> {
    control::toggle(control::hub()).await.map_err(failure)
}
#[tauri::command]
fn autostart(
    enabled: Option<bool>,
    app: tauri::AppHandle,
    backend: State<'_, Arc<Backend>>,
) -> Result<bool, String> {
    let launch = app.autolaunch();
    if let Some(enabled) = enabled {
        if enabled {
            launch.enable()
        } else {
            launch.disable()
        }
        .map_err(failure)?;
        let _ = backend::log(&backend.root, LogEvent::AutostartChanged);
    }
    launch.is_enabled().map_err(failure)
}
fn main() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .args(["--autostart"])
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            snapshot, pair, confirm, cancel, revoke, toggle, autostart
        ])
        .setup(|app| {
            let backend = Backend::open(control::default_state_dir())?;
            let _ = backend::log(&backend.root, LogEvent::Started);
            app.manage(backend.clone());
            let open =
                MenuItem::with_id(app, "open", "Pair a phone / Devices…", true, None::<&str>)?;
            let toggle = MenuItem::with_id(
                app,
                "toggle",
                "Request dictation toggle",
                true,
                None::<&str>,
            )?;
            let quit = MenuItem::with_id(app, "quit", "Quit Voice Receiver", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &toggle, &quit])?;
            let tray = TrayIconBuilder::with_id("receiver")
                .icon(tauri::image::Image::new_owned(
                    model::icon_rgba(model::Icon::Unknown),
                    32,
                    32,
                ))
                .tooltip("Voice Receiver · phone state unknown")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "toggle" => {
                        tauri::async_runtime::spawn(async {
                            let _ = control::toggle(control::hub()).await;
                        });
                    }
                    "quit" => {
                        let backend = app.state::<Arc<Backend>>();
                        let _ = backend::log(&backend.root, LogEvent::Stopped);
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;
            if !std::env::args().any(|a| a == "--autostart") {
                if let Some(window) = app.get_webview_window("main") {
                    window.show()?;
                }
            }
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                backend.start();
                let mut seen = 0;
                let mut flashing_until = Instant::now();
                loop {
                    if let Ok(snapshot) = backend.snapshot() {
                        if snapshot.status.flash != seen {
                            seen = snapshot.status.flash;
                            flashing_until = Instant::now() + Duration::from_millis(900);
                        }
                        let flash = Instant::now() < flashing_until;
                        let icon = model::icon(&snapshot.status, flash);
                        let icon_ready = tray
                            .set_icon(Some(tauri::image::Image::new_owned(
                                model::icon_rgba(icon),
                                32,
                                32,
                            )))
                            .is_ok();
                        let mode = match snapshot.status.mode {
                            Some(voiceremote_core::protocol::Mode::Dictation) => "Dictation",
                            Some(_) => "AI Control",
                            None => "Mode unknown",
                        };
                        let capture = match snapshot.status.listening {
                            Some(false) => "Not listening",
                            Some(true) => "Listening",
                            None => "Capture unknown",
                        };
                        let _ =
                            tray.set_tooltip(Some(format!("Voice Receiver · {mode} · {capture}")));
                        // This window is configured nonfocusable and ignores all cursor events.
                        // Showing it never calls set_focus; it contains no transcript.
                        if let Some(overlay) = handle.get_webview_window("overlay") {
                            let _ = overlay.set_ignore_cursor_events(true);
                            if flash {
                                let shown = overlay.show().is_ok();
                                control::presented(
                                    control::hub(),
                                    snapshot.status.flash,
                                    icon_ready && shown,
                                );
                            } else {
                                let _ = overlay.hide();
                            }
                        }
                    }
                    tokio::time::sleep(Duration::from_millis(150)).await;
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("Voice Receiver could not start");
}
