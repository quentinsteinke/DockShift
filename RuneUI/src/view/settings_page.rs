use super::*;

pub(super) fn settings(s: &State, p: Paint) -> El {
    let mut body=col().w_full().gap(20.0).child(label("Quietly, your way.",30.0,650.0,p.ink))
        .child(label("The details that make DockShift feel at home.",12.0,450.0,p.muted))
        .child(card(p).w_full().child(heading("GENERAL",p))
            .child(setting_toggle("login","Open DockShift at login",if s.data.login_available {"Be ready when your Mac is."} else {"Install in Applications to enable this."},s.data.login,p,"login").unavailable(!s.data.login_available))
            .children(s.data.login_approval.then(||action("approve-login","Approve in Login Items…",p,false,"loginSettings","")))
            .child(line(p)).child(setting_toggle("paused","Pause switching","Keep the current setup until you resume.",s.data.paused,p,"pause").unavailable(s.data.paused&&!s.data.can_resume))
            .child(line(p)).child(setting_toggle("remember-edits","Remember manual Dock edits","Save changes into the profile you’re using before switching away.",s.data.remember_edits,p,"rememberEdits")))
        .child(card(p).w_full().child(heading("WHEN RULES OVERLAP",p))
            .child(precedence(s,p,"Dock",false)).child(line(p)).child(precedence(s,p,"Wallpaper",true))
            .child(label("An empty Dock or wallpaper inherits from the other rule, then Default.",10.5,450.0,p.muted).wrap().w_full()))
        .child(card(p).w_full().child(heading("UPDATES",p))
            .child(setting_toggle("auto-updates","Automatically check for updates","Checks daily. Always asks before installing.",s.data.automatic_updates,p,"autoUpdates").unavailable(!s.data.update_problem.is_empty()))
            .child(action("check-updates","Check for updates…",p,false,"checkUpdates","").unavailable(!s.data.can_update))
            .children((!s.data.update_problem.is_empty()).then(||label(&s.data.update_problem,11.0,450.0,p.muted).wrap().w_full())))
        .child(card(p).w_full().child(heading("RESTORE YOUR ORIGINAL SETUP",p))
            .child(label("Put back your first saved Dock and every wallpaper DockShift replaced. Profiles stay saved, and automatic switching pauses.",11.5,450.0,p.muted).wrap().w_full())
            .child(button("restore-original","Restore original…",p,false,|s|s.modal="restore".into())))
        .child(card(p).w_full().child(heading("TROUBLESHOOTING",p))
            .child(label(format!("{} Dock restarts in the last hour",s.data.restarts),12.0,500.0,p.ink))
            .child(row().gap(8.0).child(action("show-data","Show data folder",p,false,"showData",""))
                .child(action("show-logs","Open Console",p,false,"logs",""))
                .child(action("retry","Retry Dock",p,false,"retry",""))
                .child(action("reset-throttle","Reset throttle",p,false,"resetThrottle",""))));
    if !s.data.warnings.is_empty() {
        body = body.child(
            card(p)
                .w_full()
                .children(
                    s.data
                        .warnings
                        .iter()
                        .map(|w| label(w, 11.5, 500.0, color("#B85646")).wrap().w_full()),
                )
                .child(action(
                    "reveal-warning",
                    "Show affected file",
                    p,
                    false,
                    "revealWarning",
                    "",
                ))
                .child(action(
                    "dismiss-warning",
                    "Dismiss notice",
                    p,
                    false,
                    "dismissWarning",
                    "",
                )),
        );
    }
    body.child(label(
        format!("DockShift {}  ·  Made for your Mac.", s.data.version),
        10.0,
        450.0,
        p.muted,
    ))
}
pub(super) fn precedence(s: &State, p: Paint, title: &str, wall: bool) -> El {
    let value = if wall {
        &s.data.wallpaper_precedence
    } else {
        &s.data.dock_precedence
    };
    let mut r = row()
        .gap(6.0)
        .center_y()
        .child(label(title, 12.0, 550.0, p.ink).grow(1.0));
    for (v, title) in [("focusWins", "Focus wins"), ("desktopWins", "Desktop wins")] {
        r = r.child(button(
            &format!("precedence-{}-{v}", if wall { "wallpaper" } else { "dock" }),
            title,
            p,
            value == v,
            move |s| {
                s.send(
                    if wall {
                        "wallpaperPrecedence"
                    } else {
                        "dockPrecedence"
                    },
                    "",
                    json!(v),
                )
            },
        ));
    }
    r
}
