use super::*;

pub(super) fn modal(s: &State, p: Paint, w: f32, h: f32) -> El {
    let create = s.modal == "new";
    let rename = s.modal == "rename";
    let mut c = card(p)
        .key("modal-card")
        .modal(true, |s: &mut State| s.modal.clear())
        .w(420.0)
        .padding(28.0)
        .gap(18.0)
        .shadow(18.0, 60.0, Color::BLACK.alpha(0.2));
    c = c.child(
        label(
            match s.modal.as_str() {
                "new" => "Make room for a new mode.",
                "rename" => "Give it a name.",
                "delete" => "Delete this profile?",
                _ => "Back to the original?",
            },
            23.0,
            650.0,
            p.ink,
        )
        .wrap()
        .w_full(),
    );
    if create || rename {
        c = c.child(
            TextInput::new(&s.name)
                .placeholder("Work, writing, after hours…")
                .on_edit(|s: &mut State| &mut s.name)
                .build(&Kit::neutral(s.dark))
                .key("profile-name")
                .w_full(),
        );
        if create {
            c = c.child(
                row()
                    .w_full()
                    .gap(18.0)
                    .center_y()
                    .child(
                        col()
                            .gap(5.0)
                            .grow(1.0)
                            .child(label("Start with my current setup", 12.0, 550.0, p.ink))
                            .child(label(
                                "Otherwise, inherit the Dock and wallpaper.",
                                10.5,
                                450.0,
                                p.muted,
                            )),
                    )
                    .child(toggle(
                        "capture-new",
                        "Start with my current setup",
                        s.capture,
                        p,
                        |s| s.capture = !s.capture,
                    )),
            );
        }
    } else {
        c=c.child(label(if s.modal=="delete" {"Its desktop rules will be removed. Your other profiles and original setup stay saved."} else {"Your saved profiles stay. Automatic switching pauses after the original Dock and wallpapers return."},12.0,450.0,p.muted).wrap().w_full());
    }
    c = c.child(
        row()
            .gap(8.0)
            .child(el().grow(1.0))
            .child(button("modal-cancel", "Cancel", p, false, |s| {
                s.modal.clear()
            }))
            .child(
                button(
                    "modal-confirm",
                    if create {
                        "Create profile"
                    } else if rename {
                        "Save name"
                    } else if s.modal == "delete" {
                        "Delete profile"
                    } else {
                        "Restore"
                    },
                    p,
                    true,
                    |s| {
                        if (s.modal == "new" || s.modal == "rename")
                            && s.name.text.trim().is_empty()
                        {
                            return;
                        }
                        let id = s.selected.clone();
                        match s.modal.as_str() {
                            "new" => s.send(
                                "create",
                                "",
                                json!({"name":s.name.text.trim(),"capture":s.capture}),
                            ),
                            "rename" => s.send("rename", &id, json!(s.name.text.trim())),
                            "delete" => {
                                s.send("delete", &id, Value::Null);
                                s.page = "profiles".into();
                            }
                            _ => s.send("restore", "", Value::Null),
                        }
                        s.modal.clear();
                    },
                )
                .unavailable((create || rename) && s.name.text.trim().is_empty())
                .default_button(),
            ),
    );
    el().key("modal-backdrop")
        .absolute(0.0, 0.0)
        .size(w, h)
        .fill(Color::BLACK.alpha(0.25))
        .center()
        .child(c.transition(Transition::blur_replace()))
}
