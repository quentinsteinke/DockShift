use super::*;

pub(super) fn desktops(s: &State, p: Paint, w: f32) -> El {
    let mut body = col()
        .w_full()
        .gap(20.0)
        .child(label("A change of space.", 30.0, 650.0, p.ink))
        .child(label(
            "Give each desktop its own setup. Swipe across, and your Dock follows.",
            12.0,
            450.0,
            p.muted,
        ));
    if !s.data.spaces_available {
        return body.child(
            card(p)
                .child(label(
                    "Desktop detection is unavailable on this Mac.",
                    13.0,
                    550.0,
                    p.ink,
                ))
                .child(label(
                    "Profiles and Focus rules still work.",
                    12.0,
                    450.0,
                    p.muted,
                )),
        );
    }
    for d in &s.data.desktops {
        let pf = s
            .data
            .profiles
            .iter()
            .find(|p| p.id == d.profile_id)
            .or_else(|| s.data.profiles.iter().find(|p| p.is_default));
        let key = d.key.clone();
        let mut c = card(p).w_full().child(
            row()
                .gap(12.0)
                .center_y()
                .child(glyph(&DESKTOP, 20.0, p.accent))
                .child(
                    col()
                        .grow(1.0)
                        .gap(3.0)
                        .child(label(&d.label, 15.0, 650.0, p.ink))
                        .child(label(&d.display, 10.0, 450.0, p.muted)),
                )
                .children(d.current.then(|| badge("YOU ARE HERE", p.green, p))),
        );
        if let Some(pf) = pf {
            c = c.child(desktop_preview(s, pf, p, (w - 104.0).min(680.0), 190.0));
        }
        let current = s
            .data
            .profiles
            .iter()
            .find(|p| p.id == d.profile_id)
            .map_or("No rule, follow Focus or Default", |p| p.name.as_str());
        let picker_key = format!("desktop-{}", d.key);
        let picker = picker_key.clone();
        c = c.child(button(
            &picker_key,
            &format!("{current}   ▾"),
            p,
            false,
            move |s| {
                s.picker = if s.picker == picker {
                    String::new()
                } else {
                    picker.clone()
                }
            },
        ));
        if s.picker == picker_key {
            let mut options = col().key(format!("options-{key}")).gap(5.0).w_full();
            let k = key.clone();
            options = options.child(button(
                &format!("assign-none-{key}"),
                "No rule",
                p,
                false,
                move |s| {
                    s.send("assign", &k, Value::Null);
                    s.picker.clear();
                },
            ));
            for pf in &s.data.profiles {
                let (k, id) = (key.clone(), pf.id.clone());
                options = options.child(button(
                    &format!("assign-{}-{key}", pf.id),
                    &pf.name,
                    p,
                    false,
                    move |s| {
                        s.send("assign", &k, json!(id));
                        s.picker.clear();
                    },
                ));
            }
            c = c.child(options);
        }
        body = body.child(c);
    }
    body.child(card(p).w_full().child(heading("SWITCHING BEHAVIOR",p))
        .child(setting_toggle("desktop-dock","Change Dock when switching desktops","Different layouts cause a brief Dock restart.",s.data.desktop_dock,p,"desktopDock"))
        .child(setting_dwell(s,p))
        .child(action("mission-control","Open Mission Control",p,false,"missionControl",""))
        .child(label("Full-screen apps keep the last desktop’s Dock. macOS turns off Show on all Spaces when a desktop gets its own wallpaper.",11.0,450.0,p.muted).wrap().w_full()))
}

pub(super) fn setting_dwell(s: &State, p: Paint) -> El {
    let mut r = row()
        .gap(6.0)
        .center_y()
        .child(label("Wait before changing Dock", 12.0, 500.0, p.ink).grow(1.0));
    for value in [0.5, 1.2, 2.0, 3.0] {
        r = r.child(button(
            &format!("dwell-{value}"),
            &format!("{value:.1}s"),
            p,
            (s.data.dwell - value).abs() < 0.01,
            move |s| s.send("dwell", "", json!(value)),
        ));
    }
    r
}
pub(super) fn focus(s: &State, p: Paint) -> El {
    let mut body = col()
        .w_full()
        .gap(20.0)
        .child(label("Less switching. More focus.", 30.0, 650.0, p.ink))
        .child(label(
            "Your Mac’s Focus modes can bring the right setup with them.",
            12.0,
            450.0,
            p.muted,
        ));
    for (n, title, detail) in [
        (
            "01",
            "Make your profile",
            "Save the apps and wallpaper you want for work, writing, or winding down.",
        ),
        (
            "02",
            "Connect a Focus filter",
            "In System Settings → Focus, choose a Focus, then Add Filter → DockShift. Pick your profile.",
        ),
        (
            "03",
            "Let your Mac take it from here",
            "Scheduled, manual, or synced from your iPhone. When Focus ends, DockShift returns to your rules.",
        ),
    ] {
        body = body.child(
            card(p).w_full().child(
                row()
                    .gap(20.0)
                    .items_start()
                    .child(label(n, 22.0, 450.0, p.accent))
                    .child(
                        col()
                            .grow(1.0)
                            .gap(7.0)
                            .child(label(title, 15.0, 650.0, p.ink))
                            .child(label(detail, 12.0, 450.0, p.muted).wrap().w_full()),
                    ),
            ),
        );
    }
    body.child(row().gap(10.0).child(action("open-focus","Open Focus settings  ↗",p,true,"focusSettings",""))
        .child(action("check-focus","Check now",p,false,"checkFocus","")))
        .child(card(p).w_full().child(heading("LIVE STATUS",p)).child(label(&s.data.focus,15.0,600.0,p.ink))
            .child(label(&s.data.focus_status,11.0,450.0,p.muted).wrap().w_full())
            .child(action("clear-focus","Clear manual choice",p,false,"stop","")))
        .child(card(p).w_full().child(heading("SHORTCUTS BACKUP",p))
            .child(label("Create two Focus automations in Shortcuts. Use Set DockShift Focus Profile with your profile when Focus turns on, and without a profile when it turns off.",11.5,450.0,p.muted).wrap().w_full())
            .child(action("open-shortcuts","Open Shortcuts  ↗",p,false,"shortcuts","")))
}
