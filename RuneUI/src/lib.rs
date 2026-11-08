mod model;
mod style;
mod view;

use model::{Snapshot, State};
use rune::{AppSpec, Key, KeyEvent, Mods, embed::LayerHost};
use serde_json::json;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::Arc,
};

pub fn preview_spec() -> AppSpec<State> {
    AppSpec {
        scenes: &[
            ("dark", |s| s.dark = true),
            ("profiles", |s| s.page = "profiles".into()),
            ("studio", |s| s.open_profile("work")),
            ("studio-dark", |s| {
                s.open_profile("work");
                s.dark = true;
            }),
            ("desktops", |s| s.page = "desktops".into()),
            ("settings", |s| s.page = "settings".into()),
            ("focus", |s| s.page = "focus".into()),
            ("new", |s| s.modal = "new".into()),
            ("menu", |s| s.data.menu = true),
            ("art-coast", |s| s.page = "art-0".into()),
            ("art-dusk", |s| s.page = "art-1".into()),
            ("art-clay", |s| s.page = "art-2".into()),
        ],
        ..AppSpec::new(
            "DockShift · Rune",
            (1140.0, 800.0),
            model::fixture,
            view::view,
        )
    }
}

struct Host {
    layer: LayerHost<State>,
    images_pending: bool,
    clipboard: rune::clipboard::MemoryClipboard,
}
fn cstring(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}
unsafe fn string(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }
}
unsafe fn with_host<R: Default>(p: *mut c_void, f: impl FnOnce(&mut Host) -> R) -> R {
    if p.is_null() {
        return R::default();
    }
    catch_unwind(AssertUnwindSafe(|| f(unsafe { &mut *p.cast::<Host>() }))).unwrap_or_default()
}

// Every host call, including destruction, belongs on AppKit's main thread. The Swift host owns
// the CAMetalLayer for strictly longer than this handle. No pointer escapes to a worker.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_create(
    layer: *mut c_void,
    width: f32,
    height: f32,
    scale: f32,
    dark: bool,
    data: *const c_char,
) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = State {
            dark,
            ..State::default()
        };
        state.update(serde_json::from_str::<Snapshot>(&unsafe { string(data) }).ok()?);
        let spec = AppSpec::new("DockShift", (width, height), State::default, view::view);
        let reduced_motion = state.data.reduced_motion;
        let mut layer = unsafe {
            LayerHost::from_core_animation_layer(
                layer,
                &spec,
                state,
                (width, height),
                scale,
                dark,
                Arc::new(|| {}),
            )
        }
        .map_err(|e| eprintln!("DockShift Rune: {e}"))
        .ok()?;
        let clipboard = rune::clipboard::memory();
        layer.runtime_mut().use_clipboard(&clipboard);
        layer
            .runtime_mut()
            .set_system_reduced_motion(reduced_motion);
        Some(
            Box::into_raw(Box::new(Host {
                layer,
                images_pending: true,
                clipboard,
            }))
            .cast::<c_void>(),
        )
    }))
    .ok()
    .flatten()
    .unwrap_or(std::ptr::null_mut())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_destroy(p: *mut c_void) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(p.cast::<Host>()) })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_update(p: *mut c_void, data: *const c_char) {
    unsafe {
        with_host(p, |h| {
            if let Ok(data) = serde_json::from_str::<Snapshot>(&string(data)) {
                h.layer
                    .runtime_mut()
                    .set_system_reduced_motion(data.reduced_motion);
                h.layer.runtime_mut().state.update(data);
                h.layer.runtime_mut().invalidate();
            }
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_resize(p: *mut c_void, w: f32, h: f32, scale: f32) {
    unsafe { with_host(p, |host| host.layer.resize((w, h), scale)) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_frame(p: *mut c_void) -> bool {
    unsafe {
        with_host(p, |h| {
            let pending = h
                .layer
                .runtime()
                .state
                .images
                .values()
                .any(|i| !i.is_ready());
            if pending || h.images_pending {
                h.layer.runtime_mut().invalidate();
            }
            h.images_pending = pending;
            let frame = h.layer.frame();
            frame.animating || pending || frame.wake_after_secs.is_some()
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_pointer(p: *mut c_void, kind: i32, x: f32, y: f32, dy: f32) {
    unsafe {
        with_host(p, |h| {
            let rt = h.layer.runtime_mut();
            match kind {
                0 => rt.pointer_move(x, y),
                1 => rt.pointer_down(x, y),
                2 => rt.pointer_up(x, y),
                3 => rt.wheel(x, y, dy),
                _ => rt.pointer_leave(),
            }
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_wheel(p: *mut c_void, x: f32, y: f32, dx: f32, dy: f32) {
    unsafe { with_host(p, |h| h.layer.runtime_mut().wheel_xy(x, y, dx, dy)) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_key(p: *mut c_void, key: *const c_char, mods: u32) {
    unsafe {
        with_host(p, |h| {
            let s = string(key);
            let m = Mods {
                shift: mods & 1 != 0,
                cmd: mods & 2 != 0,
                logo: mods & 2 != 0,
                alt: mods & 4 != 0,
                ctrl: mods & 8 != 0,
            };
            let key = match s.as_str() {
                "Return" => Key::Enter,
                "Tab" => Key::Tab,
                "Escape" => Key::Escape,
                "Backspace" => Key::Backspace,
                "Delete" => Key::Delete,
                "Left" => Key::Left,
                "Right" => Key::Right,
                "Up" => Key::Up,
                "Down" => Key::Down,
                "Home" => Key::Home,
                "End" => Key::End,
                _ => {
                    if m.cmd {
                        Key::Command(s.chars().next().unwrap_or(' '))
                    } else {
                        Key::Text(s)
                    }
                }
            };
            h.layer.runtime_mut().key(KeyEvent { key, mods: m });
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_text(p: *mut c_void, text: *const c_char) {
    unsafe { with_host(p, |h| h.layer.runtime_mut().paste(string(text))) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_ime(
    p: *mut c_void,
    text: *const c_char,
    start: usize,
    end: usize,
    commit: bool,
) {
    unsafe {
        with_host(p, |h| {
            let text = string(text);
            h.layer.runtime_mut().ime(if commit {
                rune::Ime::Commit(text)
            } else {
                rune::Ime::Preedit(text, Some((start, end)))
            });
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_select(p: *mut c_void, id: *const c_char) {
    unsafe {
        with_host(p, |h| {
            h.layer.runtime_mut().state.open_profile(&string(id));
            h.layer.runtime_mut().invalidate();
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_reduced_motion(p: *mut c_void, on: bool) {
    unsafe { with_host(p, |h| h.layer.runtime_mut().set_system_reduced_motion(on)) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_actions(p: *mut c_void) -> *mut c_char {
    unsafe {
        with_host(p, |h| {
            let actions = std::mem::take(&mut h.layer.runtime_mut().state.actions);
            cstring(serde_json::to_string(&actions).unwrap())
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_copy(p: *mut c_void) -> *mut c_char {
    unsafe {
        with_host(p, |h| {
            let Some(text) = h.clipboard.text() else {
                return std::ptr::null_mut();
            };
            let result = cstring(text.to_string());
            h.clipboard = rune::clipboard::memory();
            h.layer.runtime_mut().use_clipboard(&h.clipboard);
            result
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_elements(p: *mut c_void) -> *mut c_char {
    unsafe {
        with_host(p, |h| {
            let rt = h.layer.runtime();
            let elements = rt.elements();
            let nodes: Vec<_> = elements.iter().filter(|e| {
                if e.inert || e.exiting || e.opacity <= 0.05 || e.visible[2] <= 0.0 || e.visible[3] <= 0.0 { return false; }
                // A control already names itself. Do not make VoiceOver read its text twice.
                if e.role == "text" {
                    let mut parent = e.parent;
                    while let Some(i) = parent {
                        if matches!(elements[i].role, "button" | "switch" | "textbox") { return false; }
                        parent = elements[i].parent;
                    }
                }
                true
            }).map(|e| {
                let value = if e.role == "textbox" { json!(rt.state.name.text) } else {
                    match e.key.as_deref().unwrap_or("") {
                        "login" => json!(rt.state.data.login),
                        "paused" | "quick-pause" => json!(rt.state.data.paused),
                        "remember-edits" => json!(rt.state.data.remember_edits),
                        "desktop-dock" => json!(rt.state.data.desktop_dock),
                        "auto-updates" => json!(rt.state.data.automatic_updates),
                        "capture-new" => json!(rt.state.capture),
                        _ => serde_json::Value::Null,
                    }
                };
                json!({"key":e.key,"path":e.path,"role":e.role,"label":e.label.as_ref().or(e.text.as_ref()),
                    "value":value,"rect":e.visible,"focusable":e.focusable,"focused":e.focused,"help":e.help})
            }).collect();
            cstring(serde_json::to_string(&nodes).unwrap())
        })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ds_free(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) })
    }
}

#[cfg(test)]
mod tests;
