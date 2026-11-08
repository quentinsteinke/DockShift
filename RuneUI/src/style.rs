use crate::model::State;
use rune::{Color, El, Icon, Spring, TextStyle, el, icon, row, text};

#[derive(Clone, Copy)]
pub struct Paint {
    pub bg: Color,
    pub sidebar: Color,
    pub card: Color,
    pub ink: Color,
    pub muted: Color,
    pub line: Color,
    pub accent: Color,
    pub wash: Color,
    pub green: Color,
}
pub fn color(s: &str) -> Color {
    rune::color::hex(s).unwrap()
}
impl Paint {
    pub fn new(dark: bool) -> Self {
        if dark {
            Self {
                bg: color("#11151C"),
                sidebar: color("#171D26"),
                card: color("#1C2430"),
                ink: color("#F2F5FC"),
                muted: color("#9AA9BE"),
                line: color("#2E3949"),
                accent: color("#91B6FF"),
                wash: color("#283C5D"),
                green: color("#88DAB7"),
            }
        } else {
            Self {
                bg: color("#FAFBFD"),
                sidebar: color("#F0F3F8"),
                card: Color::WHITE,
                ink: color("#1C2C42"),
                muted: color("#687991"),
                line: color("#E1E7F0"),
                accent: color("#345FBE"),
                wash: color("#E8EFFC"),
                green: color("#287858"),
            }
        }
    }
}
pub fn label(s: impl Into<String>, size: f32, weight: f32, c: Color) -> El {
    text(s.into()).font(TextStyle::new(size, weight)).color(c)
}
pub fn heading(s: &str, p: Paint) -> El {
    label(s, 12.0, 650.0, p.muted)
}
pub fn card(p: Paint) -> El {
    rune::col()
        .padding(22.0)
        .gap(16.0)
        .radius(18.0)
        .fill(p.card)
        .border(1.0, p.line)
}
pub fn line(p: Paint) -> El {
    el().w_full().h(1.0).fill(p.line)
}
pub trait Availability {
    fn unavailable(self, on: bool) -> El;
}
impl Availability for El {
    fn unavailable(self, on: bool) -> El {
        if on {
            self.disabled(true).inert().opacity(0.45)
        } else {
            self
        }
    }
}
pub fn button(
    key: &str,
    title: &str,
    p: Paint,
    primary: bool,
    f: impl Fn(&mut State) + 'static,
) -> El {
    row()
        .key(key)
        .role("button")
        .label(title)
        .focusable(true)
        .h(36.0)
        .px(15.0)
        .gap(8.0)
        .center()
        .radius(10.0)
        .fill(if primary { p.accent } else { p.card })
        .border(1.0, if primary { p.accent } else { p.line })
        .hover(if primary {
            Color::WHITE.alpha(0.1)
        } else {
            p.accent.alpha(0.07)
        })
        .press_scale(0.98)
        .motion(Spring::new(0.25, 0.08))
        .on_press(f)
        .child(label(
            title,
            12.0,
            600.0,
            if primary { p.bg } else { p.ink },
        ))
}
pub fn action(key: &str, title: &str, p: Paint, primary: bool, action: &str, id: &str) -> El {
    let (a, id) = (action.to_owned(), id.to_owned());
    button(key, title, p, primary, move |s| {
        s.send(&a, &id, serde_json::Value::Null)
    })
}
pub fn glyph(i: &'static Icon, size: f32, c: Color) -> El {
    icon(i, size).color(c)
}
pub fn toggle(key: &str, name: &str, on: bool, p: Paint, f: impl Fn(&mut State) + 'static) -> El {
    el().key(key)
        .role("switch")
        .label(name)
        .checked(on)
        .focusable(true)
        .size(34.0, 20.0)
        .radius(10.0)
        .fill(if on { p.accent } else { p.muted.alpha(0.3) })
        .on_press(f)
        .child(
            el().key("thumb")
                .absolute(if on { 16.0 } else { 2.0 }, 2.0)
                .size(16.0, 16.0)
                .radius(8.0)
                .fill(Color::WHITE)
                .motion(Spring::new(0.25, 0.05)),
        )
}
pub static GRID: Icon = Icon {
    name: "ds-grid",
    view: 24.0,
    body: r#"<rect x="3" y="3" width="7" height="7" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="14" y="3" width="7" height="7" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="3" y="14" width="7" height="7" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="14" y="14" width="7" height="7" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/>"#,
};
pub static DESKTOP: Icon = Icon {
    name: "ds-desktop",
    view: 24.0,
    body: r#"<rect x="2.5" y="4" width="19" height="13" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 21h8m-4-4v4" stroke="currentColor" stroke-width="1.5"/>"#,
};
pub static MOON: Icon = Icon {
    name: "ds-moon",
    view: 24.0,
    body: r#"<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z" fill="none" stroke="currentColor" stroke-width="1.5"/>"#,
};
pub static SLIDERS: Icon = Icon {
    name: "ds-sliders",
    view: 24.0,
    body: r#"<path d="M4 7h16M4 17h16" stroke="currentColor" stroke-width="1.5"/><circle cx="9" cy="7" r="3" fill="currentColor"/><circle cx="15" cy="17" r="3" fill="currentColor"/>"#,
};
pub static PLUS: Icon = Icon {
    name: "ds-plus",
    view: 24.0,
    body: r#"<path d="M12 5v14M5 12h14" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>"#,
};
