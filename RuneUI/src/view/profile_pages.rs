use super::*;

pub(super) fn overview(s: &State, p: Paint, w: f32) -> El {
    let pf = s
        .data
        .profiles
        .iter()
        .find(|p| p.id == s.data.active_profile)
        .or(s.data.profiles.first());
    let mut body = col().w_full().gap(24.0);
    if let Some(pf) = pf {
        let pw = (w - 58.0).min(850.0);
        let id = pf.id.clone();
        body = body.child(
            col()
                .key("overview-hero")
                .w_full()
                .gap(18.0)
                .child(
                    row()
                        .center_y()
                        .child(
                            col()
                                .gap(7.0)
                                .grow(1.0)
                                .child(label("Everything in its place.", 32.0, 650.0, p.ink))
                                .child(label(
                                    "Your Dock and wallpaper, ready for whatever comes next.",
                                    12.0,
                                    450.0,
                                    p.muted,
                                )),
                        )
                        .child(button(
                            "edit-current",
                            "Edit current setup",
                            p,
                            false,
                            move |s| s.open_profile(&id),
                        )),
                )
                .child(
                    col()
                        .w_full()
                        .padding(10.0)
                        .radius(21.0)
                        .fill(p.card)
                        .border(1.0, p.line)
                        .child(desktop_preview(
                            s,
                            pf,
                            p,
                            pw - 20.0,
                            ((pw - 20.0) * 0.25).clamp(150.0, 200.0),
                        ))
                        .child(
                            row()
                                .h(40.0)
                                .px(10.0)
                                .gap(8.0)
                                .center_y()
                                .child(glyph(&DESKTOP, 15.0, p.muted))
                                .child(label(&pf.name, 11.5, 650.0, p.ink))
                                .child(label("/", 11.0, 400.0, p.line))
                                .child(label(&s.data.desktop, 11.0, 450.0, p.muted))
                                .child(el().grow(1.0))
                                .child(badge(
                                    if s.data.active_profile.is_empty() {
                                        "PROFILE PREVIEW"
                                    } else {
                                        "CURRENT SETUP"
                                    },
                                    p.green,
                                    p,
                                )),
                        ),
                ),
        );
    }
    body = body.child(
        row()
            .center_y()
            .child(heading("A SETUP FOR EVERY SIDE OF YOU", p))
            .child(el().grow(1.0))
            .child(button("all-profiles", "All profiles  →", p, false, |s| {
                s.page = "profiles".into()
            })),
    );
    let cw = ((w - 58.0 - 28.0) / 3.0).max(180.0);
    let mut cards = row().gap(14.0).items_start();
    for pf in s.data.profiles.iter().filter(|p| !p.is_default).take(2) {
        cards = cards.child(profile_card(s, pf, p, cw));
    }
    cards = cards.child(new_tile(p, cw));
    body.child(cards)
}

pub(super) fn profiles(s: &State, p: Paint, w: f32) -> El {
    let cols = if w > 760.0 { 3 } else { 2 };
    let cw = (w - 58.0 - (cols - 1) as f32 * 16.0) / cols as f32;
    let mut body = col()
        .w_full()
        .gap(20.0)
        .child(label("Small worlds. All yours.", 30.0, 650.0, p.ink))
        .child(label(
            "Save a Dock and wallpaper together. Let Focus or your desktop do the switching.",
            12.0,
            450.0,
            p.muted,
        ));
    let mut cards: Vec<El> = s
        .data
        .profiles
        .iter()
        .map(|pf| profile_card(s, pf, p, cw))
        .collect();
    cards.push(new_tile(p, cw));
    while !cards.is_empty() {
        let count = cards.len().min(cols);
        body = body.child(row().gap(16.0).items_start().children(cards.drain(..count)));
    }
    body
}

pub(super) fn editor(s: &State, p: Paint, w: f32) -> El {
    let Some(pf) = s.profile() else {
        return label("Choose a profile in the sidebar.", 16.0, 500.0, p.muted);
    };
    let id = pf.id.clone();
    let active = s.data.explicit_profile == id;
    let pid = id.clone();
    let mut body = col()
        .w_full()
        .gap(21.0)
        .child(
            row()
                .gap(12.0)
                .center_y()
                .child(
                    col()
                        .gap(6.0)
                        .grow(1.0)
                        .child(label(&pf.name, 30.0, 650.0, p.ink))
                        .child(label(
                            if pf.is_default {
                                "The familiar setup you always come back to."
                            } else {
                                "A little less noise. A little more you."
                            },
                            12.0,
                            450.0,
                            p.muted,
                        )),
                )
                .child(button("rename-profile", "Rename", p, false, move |s| {
                    s.name = rune::TextEdit::new(s.profile().map_or("", |p| p.name.as_str()));
                    s.modal = "rename".into();
                }))
                .child(action(
                    "use-profile",
                    if active { "Stop using" } else { "Use profile" },
                    p,
                    true,
                    if active { "stop" } else { "use" },
                    &pid,
                )),
        )
        .child(desktop_preview(
            s,
            pf,
            p,
            w - 58.0,
            ((w - 58.0) * 0.40).min(310.0),
        ));
    let mut apps = row().gap(9.0).items_start();
    for (i, t) in pf.tiles.iter().enumerate() {
        let selected = s.selected_tile == Some(i);
        let icon = if let Some(img) = s.images.get(&t.path) {
            el().size(38.0, 38.0)
                .pixels_fit(img.pixels(), SurfaceFit::Fit)
        } else {
            el().size(38.0, 38.0)
                .radius(9.0)
                .fill(p.wash)
                .center()
                .child(label("?", 16.0, 600.0, p.accent))
        };
        apps = apps.child(
            col()
                .key(format!("edit-tile-{i}"))
                .role("button")
                .label(format!(
                    "Select {}{}",
                    t.label,
                    if t.missing { ", missing" } else { "" }
                ))
                .focusable(true)
                .w(63.0)
                .padding(6.0)
                .gap(6.0)
                .radius(10.0)
                .fill(if selected { p.wash } else { Color::TRANSPARENT })
                .border(
                    1.0,
                    if selected {
                        p.accent
                    } else {
                        Color::TRANSPARENT
                    },
                )
                .hover(p.wash)
                .items_center()
                .on_press(move |s: &mut State| s.selected_tile = Some(i))
                .child(icon)
                .child(
                    label(
                        &t.label,
                        9.0,
                        450.0,
                        if t.missing { color("#B85646") } else { p.muted },
                    )
                    .w_full()
                    .truncate(),
                ),
        );
    }
    let mut dock = card(p)
        .w_full()
        .child(
            row()
                .center_y()
                .child(heading("DOCK", p))
                .child(el().grow(1.0))
                .child(label(
                    format!("{} items", pf.tiles.len()),
                    10.0,
                    500.0,
                    p.muted,
                )),
        )
        .child(row().w_full().h(84.0).scroll_x().child(apps));
    if let Some(i) = s.selected_tile.filter(|&i| i < pf.tiles.len()) {
        let (a, b, c) = (id.clone(), id.clone(), id.clone());
        dock = dock.child(
            row()
                .gap(8.0)
                .center_y()
                .child(label("Selected item", 10.0, 450.0, p.muted))
                .child(el().grow(1.0))
                .child(
                    button("tile-left", "← Move left", p, false, move |s| {
                        s.send("moveTile", &a, json!({"index":i,"offset":-1}));
                        s.selected_tile = Some(i.saturating_sub(1));
                    })
                    .unavailable(
                        i == 0
                            || pf
                                .tiles
                                .get(i.wrapping_sub(1))
                                .is_some_and(|t| tile_section(t) != tile_section(&pf.tiles[i])),
                    ),
                )
                .child(
                    button("tile-right", "Move right →", p, false, move |s| {
                        s.send("moveTile", &b, json!({"index":i,"offset":1}));
                        s.selected_tile = Some(i + 1);
                    })
                    .unavailable(
                        i + 1 >= pf.tiles.len()
                            || pf
                                .tiles
                                .get(i + 1)
                                .is_some_and(|t| tile_section(t) != tile_section(&pf.tiles[i])),
                    ),
                )
                .child(button("tile-remove", "Remove", p, false, move |s| {
                    s.send("removeTile", &c, json!(i));
                    s.selected_tile = None;
                })),
        );
    }
    dock = dock.child(line(p)).child(
        row()
            .gap(8.0)
            .child(action("add-app", "+ Add app", p, false, "addApp", &id))
            .child(action(
                "capture-dock",
                "Capture current Dock",
                p,
                false,
                "captureDock",
                &id,
            ))
            .child(el().grow(1.0))
            .child(action(
                "clear-dock",
                "Inherit Dock",
                p,
                false,
                "clearDock",
                &id,
            )),
    );
    if pf.unreadable {
        dock = dock.child(
            label(
                "The saved Dock could not be read. Capture it again to recover.",
                11.0,
                500.0,
                color("#B85646"),
            )
            .wrap()
            .w_full(),
        );
    }
    body = body.child(dock);
    let mut wall = card(p)
        .w_full()
        .child(heading("WALLPAPER", p))
        .child(
            row()
                .gap(10.0)
                .center_y()
                .child(
                    col()
                        .grow(1.0)
                        .gap(5.0)
                        .child(
                            label(
                                if pf.wallpaper_name.is_empty() {
                                    "Inherits your wallpaper"
                                } else {
                                    &pf.wallpaper_name
                                },
                                13.0,
                                600.0,
                                p.ink,
                            )
                            .truncate(),
                        )
                        .child(label(
                            "Images are copied into DockShift, so the original can move.",
                            10.5,
                            450.0,
                            p.muted,
                        )),
                )
                .child(action(
                    "choose-image",
                    "Choose image…",
                    p,
                    true,
                    "chooseWallpaper",
                    &id,
                )),
        )
        .child(
            row()
                .gap(8.0)
                .child(action(
                    "capture-wallpaper",
                    "Use current wallpaper",
                    p,
                    false,
                    "captureWallpaper",
                    &id,
                ))
                .child(action(
                    "clear-wallpaper",
                    "Inherit wallpaper",
                    p,
                    false,
                    "clearWallpaper",
                    &id,
                )),
        );
    if !pf.wallpaper_path.is_empty() {
        let mut placements = row()
            .gap(5.0)
            .center_y()
            .child(label("Placement", 11.0, 500.0, p.muted).mr(12.0));
        for (title, value) in [
            ("Fill", "Crop"),
            ("Fit", "SizeToFit"),
            ("Stretch", "FillScreen"),
            ("Center", "Centered"),
        ] {
            let id = id.clone();
            placements = placements.child(button(
                &format!("placement-{value}"),
                title,
                p,
                pf.placement == value,
                move |s| s.send("placement", &id, json!(value)),
            ));
        }
        wall = wall.child(placements);
        if pf.placement == "SizeToFit" || pf.placement == "Centered" {
            wall = wall.child(action(
                "fill-color",
                "Choose fill color…",
                p,
                false,
                "fillColor",
                &id,
            ));
        }
    }
    body = body.child(wall).child(
        card(p)
            .w_full()
            .child(heading("MAKE IT AUTOMATIC", p))
            .child(
                row()
                    .gap(10.0)
                    .child(button(
                        "profile-desktops",
                        "Assign to a desktop  →",
                        p,
                        false,
                        |s| s.page = "desktops".into(),
                    ))
                    .child(button(
                        "profile-focus",
                        "Connect a Focus mode  →",
                        p,
                        false,
                        |s| s.page = "focus".into(),
                    )),
            ),
    );
    if !pf.is_default {
        body = body.child(row().child(el().grow(1.0)).child(button(
            "delete-profile",
            "Delete profile…",
            p,
            false,
            |s| s.modal = "delete".into(),
        )));
    }
    body
}
pub(super) fn tile_section(tile: &Tile) -> &str {
    tile.id.split_once('-').map_or("apps", |(s, _)| s)
}
