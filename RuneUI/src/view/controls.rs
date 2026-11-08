use super::*;

pub(super) fn setting_toggle(
    key: &str,
    title: &str,
    detail: &str,
    on: bool,
    p: Paint,
    action: &str,
) -> El {
    let action = action.to_owned();
    row()
        .w_full()
        .gap(18.0)
        .center_y()
        .child(
            col()
                .gap(5.0)
                .grow(1.0)
                .child(label(title, 12.0, 550.0, p.ink))
                .child(label(detail, 10.5, 450.0, p.muted).wrap().w_full()),
        )
        .child(toggle(key, title, on, p, move |s| {
            s.send(&action, "", json!(!on))
        }))
}
