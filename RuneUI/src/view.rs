use crate::{model::*, style::*};
use rune::{Color, Cx, El, ScrollSpec, Spring, SurfaceFit, Transition, col, el, row};
use rune_kit::{Kit, TextInput};
use serde_json::{Value, json};

mod previews;
use previews::*;
mod profile_pages;
use profile_pages::*;
mod automation;
use automation::*;
mod settings_page;
use settings_page::*;
mod dialog;
use dialog::*;
mod controls;
use controls::*;

fn nav(
    key: &str,
    title: &str,
    i: &'static rune::Icon,
    selected: bool,
    p: Paint,
    f: impl Fn(&mut State) + 'static,
) -> El {
    row()
        .key(key)
        .role("button")
        .label(title)
        .focusable(true)
        .h(40.0)
        .w_full()
        .px(12.0)
        .gap(11.0)
        .center_y()
        .radius(10.0)
        .fill(if selected { p.card } else { Color::TRANSPARENT })
        .border(1.0, if selected { p.line } else { Color::TRANSPARENT })
        .hover(p.accent.alpha(0.05))
        .on_press(f)
        .motion(Spring::new(0.27, 0.03))
        .child(glyph(i, 18.0, if selected { p.accent } else { p.muted }))
        .child(label(
            title,
            12.5,
            if selected { 650.0 } else { 500.0 },
            if selected { p.ink } else { p.muted },
        ))
}

fn sidebar(s: &State, p: Paint) -> El {
    let mut side = col()
        .w(212.0)
        .h_full()
        .shrink()
        .padding(18.0)
        .pt(24.0)
        .gap(7.0)
        .fill(p.sidebar)
        .child(
            row()
                .h(42.0)
                .gap(10.0)
                .center_y()
                .child(
                    el().size(30.0, 30.0)
                        .radius(9.0)
                        .fill(p.ink)
                        .center()
                        .child(glyph(&DESKTOP, 20.0, p.bg)),
                )
                .child(label("DockShift", 17.0, 700.0, p.ink)),
        )
        .child(label("A place for every mode.", 10.5, 450.0, p.muted).mb(24.0));
    for (key, title, i) in [
        ("overview", "Overview", &GRID),
        ("profiles", "Profiles", &DESKTOP),
        ("desktops", "Desktops", &DESKTOP),
        ("focus", "Focus modes", &MOON),
    ] {
        let k = key.to_owned();
        side = side.child(nav(
            &format!("nav-{key}"),
            title,
            i,
            s.page == key,
            p,
            move |s| {
                s.page = k.clone();
                s.picker.clear();
            },
        ));
    }
    side = side.child(heading("YOUR PROFILES", p).mt(26.0).mb(8.0));
    let mut profiles = col().gap(4.0).w_full();
    for (index, profile) in s.data.profiles.iter().enumerate() {
        let id = profile.id.clone();
        let selected = s.page == "profile" && s.selected == id;
        profiles = profiles.child(
            row()
                .key(format!("sidebar-{id}"))
                .role("button")
                .label(&profile.name)
                .focusable(true)
                .h(35.0)
                .px(11.0)
                .gap(9.0)
                .center_y()
                .radius(9.0)
                .fill(if selected { p.wash } else { Color::TRANSPARENT })
                .hover(p.wash)
                .on_press(move |s: &mut State| s.open_profile(&id))
                .child(
                    el().size(7.0, 7.0)
                        .radius(3.5)
                        .fill([p.accent, color("#9D80C5"), color("#C48A68")][index % 3]),
                )
                .child(
                    label(
                        &profile.name,
                        11.5,
                        if selected { 600.0 } else { 450.0 },
                        if selected { p.accent } else { p.muted },
                    )
                    .truncate()
                    .grow(1.0),
                )
                .children(
                    (profile.id == s.data.active_profile)
                        .then(|| el().size(5.0, 5.0).radius(2.5).fill(p.green)),
                ),
        );
    }
    side.child(
        col()
            .grow(1.0)
            .min_h(0.0)
            .scroll(ScrollSpec {
                stick_bottom: false,
            })
            .child(profiles),
    )
    .child(button("new-profile", "+  New profile", p, false, |s| {
        s.modal = "new".into();
        s.name = rune::TextEdit::new("");
    }))
    .child(line(p).mt(14.0).mb(8.0))
    .child(nav(
        "nav-settings",
        "Settings",
        &SLIDERS,
        s.page == "settings",
        p,
        |s| s.page = "settings".into(),
    ))
    .child(
        row()
            .pt(14.0)
            .gap(6.0)
            .center_y()
            .child(el().size(5.0, 5.0).radius(2.5).fill(if s.data.paused {
                p.muted
            } else {
                p.green
            }))
            .child(label(
                if s.data.paused {
                    "Switching paused"
                } else {
                    "Running quietly"
                },
                10.0,
                450.0,
                p.muted,
            )),
    )
}

fn quick_menu(s: &State, p: Paint) -> El {
    let mut content = col()
        .key("root")
        .w_full()
        .h_full()
        .padding(20.0)
        .gap(12.0)
        .fill(p.bg)
        .child(
            row()
                .center_y()
                .child(label("DockShift", 18.0, 700.0, p.ink))
                .child(el().grow(1.0))
                .child(badge(
                    if s.data.paused { "PAUSED" } else { "READY" },
                    p.green,
                    p,
                )),
        )
        .child(
            label(
                format!("{} · {}", s.data.desktop, s.data.focus),
                10.0,
                450.0,
                p.muted,
            )
            .truncate(),
        )
        .child(line(p));
    let mut profiles = col().gap(8.0).w_full();
    for pf in &s.data.profiles {
        profiles = profiles.child(action(
            &format!("quick-{}", pf.id),
            &pf.name,
            p,
            s.data.active_profile == pf.id,
            "use",
            &pf.id,
        ));
    }
    content = content.child(
        col()
            .grow(1.0)
            .min_h(0.0)
            .w_full()
            .scroll(ScrollSpec {
                stick_bottom: false,
            })
            .child(profiles),
    );
    content
        .child(line(p))
        .child(
            label(
                format!("Dock: {}", s.data.dock_status),
                10.0,
                450.0,
                p.muted,
            )
            .truncate(),
        )
        .child(
            label(
                format!("Wallpaper: {}", s.data.wallpaper_status),
                10.0,
                450.0,
                p.muted,
            )
            .truncate(),
        )
        .child(
            action(
                "quick-save",
                "Capture current Dock",
                p,
                false,
                "captureDock",
                &s.data.active_profile,
            )
            .unavailable(s.data.active_profile.is_empty()),
        )
        .child(action(
            "quick-clear",
            "Follow Focus and desktop rules",
            p,
            false,
            "stop",
            "",
        ))
        .child(setting_toggle(
            "quick-pause",
            "Pause switching",
            "",
            s.data.paused,
            p,
            "pause",
        ))
        .child(action(
            "quick-restore",
            "Restore original…",
            p,
            false,
            "confirmRestore",
            "",
        ))
        .child(
            row()
                .gap(7.0)
                .child(action(
                    "quick-open",
                    "Open DockShift  ↗",
                    p,
                    true,
                    "openMain",
                    "",
                ))
                .child(action("quick-quit", "Quit", p, false, "quit", "")),
        )
        .child(
            action(
                "quick-updates",
                "Check for updates…",
                p,
                false,
                "checkUpdates",
                "",
            )
            .unavailable(!s.data.can_update),
        )
}

pub fn view(s: &State, cx: &mut Cx<State>) -> El {
    cx.reduced_motion(s.data.reduced_motion);
    let p = Paint::new(s.dark);
    if let Some(index) = s
        .page
        .strip_prefix("art-")
        .and_then(|i| i.parse::<usize>().ok())
    {
        if let Some(pf) = s.data.profiles.get(index) {
            return image(s, &pf.wallpaper_path).key("root");
        }
    }
    if s.data.menu {
        return quick_menu(s, p);
    }
    let [w, h] = cx.layout_size("root").unwrap_or([1140.0, 800.0]);
    let content_w = (w - 212.0).max(600.0);
    let title = match s.page.as_str() {
        "profiles" => "Profiles",
        "profile" => "Profile studio",
        "desktops" => "Desktops",
        "focus" => "Focus modes",
        "settings" => "Settings",
        _ => "Overview",
    };
    let content = match s.page.as_str() {
        "profiles" => profiles(s, p, content_w),
        "profile" => editor(s, p, content_w),
        "desktops" => desktops(s, p, content_w),
        "focus" => focus(s, p),
        "settings" => settings(s, p),
        _ => overview(s, p, content_w),
    };
    let main = col()
        .grow(1.0)
        .h_full()
        .min_h(0.0)
        .fill(p.bg)
        .child(
            row()
                .h(65.0)
                .px(28.0)
                .gap(12.0)
                .center_y()
                .border(0.0, p.line)
                .child(label(title, 12.0, 650.0, p.ink))
                .child(el().grow(1.0))
                .child(glyph(&DESKTOP, 14.0, p.muted))
                .child(label(&s.data.desktop, 10.5, 500.0, p.muted))
                .child(button(
                    "appearance",
                    if s.dark { "Light" } else { "Dark" },
                    p,
                    false,
                    |s| {
                        s.dark = !s.dark;
                        s.send("appearance", "", json!(s.dark));
                    },
                ))
                .child(
                    button(
                        "pause-header",
                        if s.data.paused { "Resume" } else { "Pause" },
                        p,
                        false,
                        |s| s.send("pause", "", json!(!s.data.paused)),
                    )
                    .unavailable(s.data.paused && !s.data.can_resume),
                ),
        )
        .child(line(p))
        .child(
            col()
                .key(format!("scroll-{}", s.page))
                .grow(1.0)
                .min_h(0.0)
                .w_full()
                .scroll(ScrollSpec {
                    stick_bottom: false,
                })
                .child(
                    col().w_full().px(28.0).py(28.0).child(
                        content
                            .key(format!("page-{}-{}", s.page, s.selected))
                            .transition(Transition::blur_replace()),
                    ),
                ),
        )
        .child(line(p))
        .child(
            row()
                .h(32.0)
                .px(28.0)
                .center_y()
                .gap(7.0)
                .child(
                    el().size(5.0, 5.0)
                        .radius(2.5)
                        .fill(if s.data.error.is_empty() {
                            p.green
                        } else {
                            color("#C76F4D")
                        }),
                )
                .child(
                    label(
                        if !s.data.error.is_empty() {
                            &s.data.error
                        } else if s.data.paused {
                            "Paused. Your setup stays as it is."
                        } else if !s.data.activity.is_empty() {
                            &s.data.activity
                        } else {
                            "All settled. Your rules are ready."
                        },
                        9.5,
                        450.0,
                        p.muted,
                    )
                    .truncate()
                    .grow(1.0),
                )
                .child(label("DOCKSHIFT", 8.0, 650.0, p.muted.alpha(0.7))),
        );
    el().key("root")
        .role("group")
        .label("DockShift")
        .w_full()
        .h_full()
        .fill(p.bg)
        .child(
            row()
                .w_full()
                .h_full()
                .child(sidebar(s, p))
                .child(el().w(1.0).h_full().fill(p.line))
                .child(main),
        )
        .children((!s.modal.is_empty()).then(|| modal(s, p, w, h)))
}
