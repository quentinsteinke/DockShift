use super::*;
use rune::{Env, Runtime};
fn runtime() -> Runtime<State> {
    let mut rt = Runtime::new(
        model::fixture(),
        view::view,
        (1140.0, 800.0),
        Env::new(false, 2.0),
    );
    rt.frame(0.0);
    rt
}
fn tap(rt: &mut Runtime<State>, key: &str) {
    let (x, y) = rt.find(key).unwrap_or_else(|| panic!("missing {key}"));
    rt.pointer_down(x, y);
    rt.pointer_up(x, y);
    for _ in 0..45 {
        rt.frame(1.0 / 60.0);
    }
}

#[test]
fn navigation_opens_real_profile_editor() {
    let mut rt = runtime();
    tap(&mut rt, "sidebar-work");
    assert_eq!(rt.state.page, "profile");
    assert_eq!(rt.state.selected, "work");
    assert!(rt.find("choose-image").is_some());
}
#[test]
fn use_profile_emits_typed_command_without_editing_storage() {
    let mut rt = runtime();
    tap(&mut rt, "sidebar-work");
    tap(&mut rt, "use-profile");
    assert_eq!(
        rt.state.actions.last().unwrap(),
        &json!({"action":"use","id":"work","value":null})
    );
    assert_eq!(rt.state.data.active_profile, "default");
}
#[test]
fn new_profile_requires_name_and_cancel_is_harmless() {
    let mut rt = runtime();
    tap(&mut rt, "new-profile");
    assert_eq!(rt.state.modal, "new");
    tap(&mut rt, "modal-confirm");
    assert!(rt.state.actions.is_empty());
    assert_eq!(rt.state.modal, "new");
    tap(&mut rt, "modal-cancel");
    assert!(rt.state.modal.is_empty());
}
#[test]
fn theme_switch_changes_palette_and_emits_preference() {
    let mut rt = runtime();
    tap(&mut rt, "appearance");
    assert!(rt.state.dark);
    assert_eq!(rt.state.actions.last().unwrap()["action"], "appearance");
}
#[test]
fn snapshot_refresh_keeps_local_navigation_and_draft() {
    let mut s = model::fixture();
    s.open_profile("work");
    s.modal = "rename".into();
    s.name = rune::TextEdit::new("My draft");
    s.update(s.data.clone());
    assert_eq!(s.name.text, "My draft");
    assert_eq!(s.selected, "work");
}
#[test]
fn recapturing_a_shorter_dock_clears_stale_selection() {
    let mut rt = runtime();
    tap(&mut rt, "sidebar-work");
    rt.state.selected_tile = Some(2);
    let mut data = rt.state.data.clone();
    data.profiles
        .iter_mut()
        .find(|p| p.id == "work")
        .unwrap()
        .tiles
        .truncate(2);
    rt.state.update(data);
    rt.invalidate();
    rt.frame(0.0);
    assert_eq!(rt.state.selected_tile, None);
    assert!(rt.find("tile-remove").is_none());
}
#[test]
fn rule_owned_profile_can_be_pinned_and_wallpaper_only_override_can_be_cleared() {
    let mut rt = runtime();
    tap(&mut rt, "sidebar-default");
    tap(&mut rt, "use-profile");
    assert_eq!(rt.state.actions.last().unwrap()["action"], "use");
    let mut data = rt.state.data.clone();
    data.explicit_profile = "work".into();
    let profile = data.profiles.iter_mut().find(|p| p.id == "work").unwrap();
    profile.has_dock = false;
    profile.tiles.clear();
    rt.state.update(data);
    tap(&mut rt, "sidebar-work");
    tap(&mut rt, "use-profile");
    assert_eq!(rt.state.actions.last().unwrap()["action"], "stop");
}
#[test]
fn copy_and_cut_supply_the_embedding_clipboard_and_command_navigation_works() {
    let mut rt = runtime();
    let clipboard = rune::clipboard::memory();
    rt.use_clipboard(&clipboard);
    tap(&mut rt, "new-profile");
    rt.ime(rune::Ime::Commit("Studio".into()));
    let cmd = Mods {
        cmd: true,
        ..Default::default()
    };
    rt.key(KeyEvent {
        key: Key::Command('a'),
        mods: cmd,
    });
    rt.key(KeyEvent {
        key: Key::Command('c'),
        mods: cmd,
    });
    rt.frame(0.0);
    assert_eq!(
        clipboard.text().as_deref().map(String::as_str),
        Some("Studio")
    );
    rt.key(KeyEvent {
        key: Key::Command('x'),
        mods: cmd,
    });
    rt.frame(0.0);
    assert!(rt.state.name.text.is_empty());
    assert_eq!(
        clipboard.text().as_deref().map(String::as_str),
        Some("Studio")
    );
    rt.ime(rune::Ime::Commit("Studio".into()));
    rt.key(KeyEvent {
        key: Key::Left,
        mods: cmd,
    });
    rt.ime(rune::Ime::Commit("My ".into()));
    rt.frame(0.0);
    assert_eq!(rt.state.name.text, "My Studio");
    rt.key(KeyEvent {
        key: Key::Right,
        mods: cmd,
    });
    rt.key(KeyEvent {
        key: Key::Backspace,
        mods: cmd,
    });
    rt.frame(0.0);
    assert!(rt.state.name.text.is_empty());
}
#[test]
fn deleted_selection_returns_to_profiles() {
    let mut s = model::fixture();
    s.open_profile("work");
    let mut data = s.data.clone();
    data.profiles.retain(|p| p.id != "work");
    s.update(data);
    assert_eq!(s.page, "profiles");
    assert!(s.selected.is_empty());
}
#[test]
fn desktop_rule_selects_profile_id_not_display_name() {
    let mut rt = runtime();
    tap(&mut rt, "nav-desktops");
    tap(&mut rt, "desktop-one");
    tap(&mut rt, "assign-work-one");
    assert_eq!(
        rt.state.actions.last().unwrap(),
        &json!({"action":"assign","id":"one","value":"work"})
    );
}
#[test]
fn all_pages_keep_interactive_controls_named() {
    for page in [
        "overview", "profiles", "profile", "desktops", "focus", "settings",
    ] {
        let mut rt = runtime();
        rt.state.page = page.into();
        rt.state.selected = "work".into();
        rt.invalidate();
        rt.frame(0.0);
        for e in rt.elements() {
            if e.focusable {
                assert!(
                    e.label.as_ref().is_some_and(|l| !l.is_empty()) || e.role == "textbox",
                    "{page}: {}",
                    e.path
                );
            }
        }
    }
}

#[test]
fn create_uses_the_draft_and_local_capture_choice() {
    let mut rt = runtime();
    tap(&mut rt, "new-profile");
    tap(&mut rt, "capture-new");
    assert!(!rt.state.capture);
    assert!(rt.state.actions.is_empty());
    rt.state.name = rune::TextEdit::new("Writing");
    rt.invalidate();
    rt.frame(0.0);
    tap(&mut rt, "modal-confirm");
    assert_eq!(
        rt.state.actions.last().unwrap(),
        &json!({"action":"create","id":"","value":{"name":"Writing","capture":false}})
    );
}

#[test]
fn modal_blocks_background_navigation_and_escape_cancels() {
    let mut rt = runtime();
    let point = rt.find("nav-settings").unwrap();
    tap(&mut rt, "new-profile");
    rt.pointer_down(point.0, point.1);
    rt.pointer_up(point.0, point.1);
    rt.frame(0.0);
    assert_eq!(rt.state.page, "overview");
    rt.key(KeyEvent {
        key: Key::Escape,
        mods: Mods::default(),
    });
    rt.frame(0.0);
    assert!(rt.state.modal.is_empty());
}

#[test]
fn moving_an_app_keeps_that_position_selected_and_respects_boundaries() {
    let mut rt = runtime();
    tap(&mut rt, "sidebar-work");
    tap(&mut rt, "edit-tile-1");
    tap(&mut rt, "tile-right");
    assert_eq!(rt.state.selected_tile, Some(2));
    assert_eq!(
        rt.state.actions.last().unwrap(),
        &json!({"action":"moveTile","id":"work","value":{"index":1,"offset":1}})
    );
    let count = rt.state.actions.len();
    tap(&mut rt, "tile-right");
    assert_eq!(rt.state.actions.len(), count);
}

#[test]
fn composed_unicode_profile_names_are_preserved() {
    let mut rt = runtime();
    tap(&mut rt, "new-profile");
    rt.ime(rune::Ime::Commit("Écriture 日本語".into()));
    rt.frame(0.0);
    assert_eq!(rt.state.name.text, "Écriture 日本語");
}

#[test]
fn settings_scroll_reaches_restore_and_troubleshooting() {
    let mut rt = runtime();
    tap(&mut rt, "nav-settings");
    rt.wheel(800.0, 500.0, -3000.0);
    for _ in 0..45 {
        rt.frame(1.0 / 60.0);
    }
    let restore = rt
        .elements()
        .into_iter()
        .find(|e| e.key.as_deref() == Some("restore-original"))
        .unwrap();
    assert!(restore.visible[3] > 0.0);
    assert!(
        rt.elements()
            .iter()
            .any(|e| e.key.as_deref() == Some("show-logs") && e.visible[3] > 0.0)
    );
}
