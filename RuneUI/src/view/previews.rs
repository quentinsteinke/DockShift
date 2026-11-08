use super::*;

pub(super) fn image(s: &State, path: &str) -> El {
    let e = el().w_full().h_full();
    if let Some(i) = s.images.get(path) {
        e.pixels_fit(i.pixels(), SurfaceFit::Fill)
    } else {
        e.gradient(color("#BFD6E8"), color("#6C88A5"))
    }
}

pub(super) fn dock_preview(s: &State, pf: &Profile, p: Paint, size: f32) -> El {
    let mut dock = row()
        .key(format!("dock-preview-{}", pf.id))
        .role("group")
        .label(format!("{} Dock preview", pf.name))
        .h(size + 16.0)
        .px(9.0)
        .gap(5.0)
        .center_y()
        .radius(15.0)
        .fill(p.card.alpha(0.82))
        .border(1.0, Color::WHITE.alpha(0.4))
        .shadow(5.0, 18.0, color("#0C203B").alpha(0.12));
    for (i, t) in pf.tiles.iter().take(9).enumerate() {
        let mut icon = el()
            .key(format!("preview-icon-{i}"))
            .size(size, size)
            .radius(size * 0.22)
            .label(&t.label);
        icon = if let Some(img) = s.images.get(&t.path) {
            icon.pixels_fit(img.pixels(), SurfaceFit::Fit)
        } else {
            icon.fill(p.wash).center().child(label(
                t.label.chars().next().unwrap_or(' ').to_string(),
                size * 0.45,
                650.0,
                p.accent,
            ))
        };
        dock = dock.child(icon);
    }
    if pf.tiles.is_empty() {
        dock = dock.child(label(
            "Dock inherited from the next rule",
            10.0,
            450.0,
            p.muted,
        ));
    }
    dock
}

pub(super) fn desktop_preview(s: &State, pf: &Profile, p: Paint, width: f32, height: f32) -> El {
    let dock = dock_preview(s, pf, p, if width > 500.0 { 37.0 } else { 22.0 });
    let path = if pf.preview_path.is_empty() {
        &pf.wallpaper_path
    } else {
        &pf.preview_path
    };
    let mut wallpaper = el().w_full().h_full().fill(Color {
        r: rune::color::srgb_decode(pf.fill_color[0]),
        g: rune::color::srgb_decode(pf.fill_color[1]),
        b: rune::color::srgb_decode(pf.fill_color[2]),
        a: 1.0,
    });
    if let Some(image) = s.images.get(path) {
        wallpaper = if pf.placement == "FillScreen" {
            wallpaper.pixels(image.pixels())
        } else {
            wallpaper.pixels_fit(
                image.pixels(),
                if pf.placement == "SizeToFit" || pf.placement == "Centered" {
                    SurfaceFit::Fit
                } else {
                    SurfaceFit::Fill
                },
            )
        };
    } else {
        wallpaper = image(s, path);
    }
    el().key(format!("scene-{}", pf.id))
        .w(width)
        .h(height)
        .radius(12.0)
        .clip_rounded(12.0)
        .child(wallpaper)
        .child(
            row()
                .absolute(0.0, 0.0)
                .w_full()
                .h(19.0)
                .px(10.0)
                .gap(8.0)
                .center_y()
                .fill(Color::WHITE.alpha(0.18))
                .child(label("●", 7.0, 600.0, color("#223049")))
                .child(label("Finder", 6.5, 650.0, color("#223049"))),
        )
        .child(
            col()
                .absolute(0.0, height - if width > 500.0 { 71.0 } else { 51.0 })
                .w_full()
                .items_center()
                .child(dock),
        )
}

pub(super) fn profile_card(s: &State, pf: &Profile, p: Paint, w: f32) -> El {
    let id = pf.id.clone();
    col()
        .key(format!("profile-card-{}", pf.id))
        .role("button")
        .label(format!("Edit {}", pf.name))
        .focusable(true)
        .w(w)
        .gap(12.0)
        .padding(9.0)
        .pb(15.0)
        .radius(17.0)
        .fill(p.card)
        .border(1.0, p.line)
        .hover(p.accent.alpha(0.035))
        .press_scale(0.988)
        .on_press(move |s: &mut State| s.open_profile(&id))
        .child(desktop_preview(s, pf, p, w - 18.0, (w - 18.0) * 0.57))
        .child(
            row()
                .px(7.0)
                .center_y()
                .child(
                    col()
                        .gap(4.0)
                        .grow(1.0)
                        .child(label(&pf.name, 13.5, 650.0, p.ink))
                        .child(label(
                            if pf.is_default {
                                "Your fallback setup"
                            } else {
                                "Dock + wallpaper"
                            },
                            10.0,
                            450.0,
                            p.muted,
                        )),
                )
                .children((s.data.active_profile == pf.id).then(|| badge("IN USE", p.green, p))),
        )
}

pub(super) fn badge(title: &str, c: Color, p: Paint) -> El {
    row()
        .h(22.0)
        .px(8.0)
        .radius(6.0)
        .fill(c.alpha(0.1))
        .center()
        .child(label(
            title,
            8.5,
            700.0,
            if c == p.green { p.green } else { p.accent },
        ))
}

pub(super) fn new_tile(p: Paint, w: f32) -> El {
    col()
        .key("add-profile-card")
        .role("button")
        .label("Create profile")
        .focusable(true)
        .w(w)
        .h((w - 18.0) * 0.57 + 83.0)
        .radius(17.0)
        .border(1.0, p.line)
        .gap(12.0)
        .center()
        .hover(p.wash)
        .on_press(|s: &mut State| {
            s.modal = "new".into();
            s.name = rune::TextEdit::new("");
        })
        .child(
            el().size(36.0, 36.0)
                .radius(12.0)
                .fill(p.wash)
                .center()
                .child(glyph(&PLUS, 20.0, p.accent)),
        )
        .child(label("Make a little room", 12.0, 600.0, p.ink))
        .child(label(
            "Create a profile for your next mode",
            10.0,
            450.0,
            p.muted,
        ))
}
