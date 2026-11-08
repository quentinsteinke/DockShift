use rune::{Image, ImageCache, TextEdit};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashMap, sync::Arc};

#[derive(Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Tile {
    pub id: String,
    pub label: String,
    pub path: String,
    pub missing: bool,
}

#[derive(Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub has_dock: bool,
    pub wallpaper_path: String,
    pub preview_path: String,
    pub wallpaper_name: String,
    pub placement: String,
    pub fill_color: [f32; 3],
    pub tiles: Vec<Tile>,
    pub unreadable: bool,
}

#[derive(Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Desktop {
    pub key: String,
    pub label: String,
    pub display: String,
    pub profile_id: String,
    pub current: bool,
    pub wallpaper_path: String,
}

#[derive(Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Snapshot {
    pub profiles: Vec<Profile>,
    pub desktops: Vec<Desktop>,
    pub active_profile: String,
    pub explicit_profile: String,
    pub focus: String,
    pub focus_status: String,
    pub desktop: String,
    pub activity: String,
    pub error: String,
    pub warnings: Vec<String>,
    pub paused: bool,
    pub can_resume: bool,
    pub remember_edits: bool,
    pub desktop_dock: bool,
    pub dwell: f64,
    pub dock_precedence: String,
    pub wallpaper_precedence: String,
    pub login: bool,
    pub login_available: bool,
    pub login_approval: bool,
    pub automatic_updates: bool,
    pub can_update: bool,
    pub update_problem: String,
    pub version: String,
    pub spaces_available: bool,
    pub restarts: usize,
    pub menu: bool,
    pub reduced_motion: bool,
    pub appearance: Option<bool>,
    pub dock_status: String,
    pub wallpaper_status: String,
}

pub struct State {
    pub data: Snapshot,
    pub page: String,
    pub selected: String,
    pub dark: bool,
    pub modal: String,
    pub name: TextEdit,
    pub capture: bool,
    pub picker: String,
    pub selected_tile: Option<usize>,
    pub actions: Vec<Value>,
    pub cache: ImageCache,
    pub images: HashMap<String, Image>,
    pub headless: bool,
}

impl Default for State {
    fn default() -> Self {
        Self {
            data: Snapshot::default(),
            page: "overview".into(),
            selected: String::new(),
            dark: false,
            modal: String::new(),
            name: TextEdit::new(""),
            capture: true,
            picker: String::new(),
            selected_tile: None,
            actions: vec![],
            cache: ImageCache::new(Arc::new(|| {})),
            images: HashMap::new(),
            headless: false,
        }
    }
}

impl State {
    pub fn send(&mut self, action: &str, id: &str, value: Value) {
        self.actions
            .push(json!({"action":action,"id":id,"value":value}));
    }
    pub fn open_profile(&mut self, id: &str) {
        self.page = "profile".into();
        self.selected = id.into();
        self.selected_tile = None;
        self.picker.clear();
    }
    pub fn profile(&self) -> Option<&Profile> {
        self.data.profiles.iter().find(|p| p.id == self.selected)
    }
    pub fn update(&mut self, data: Snapshot) {
        if let Some(dark) = data.appearance {
            self.dark = dark;
        }
        self.data = data;
        if self
            .selected_tile
            .is_some_and(|i| self.profile().is_none_or(|p| i >= p.tiles.len()))
        {
            self.selected_tile = None;
        }
        if !self.selected.is_empty() && !self.data.profiles.iter().any(|p| p.id == self.selected) {
            self.selected.clear();
            self.page = "profiles".into();
        }
        self.load_images();
    }
    pub fn load_images(&mut self) {
        let mut wanted = Vec::new();
        for p in &self.data.profiles {
            if !p.wallpaper_path.is_empty() {
                wanted.push((p.wallpaper_path.clone(), false));
            }
            if !p.preview_path.is_empty() {
                wanted.push((p.preview_path.clone(), false));
            }
            for t in &p.tiles {
                if !t.path.is_empty() {
                    wanted.push((t.path.clone(), true));
                }
            }
        }
        for d in &self.data.desktops {
            if !d.wallpaper_path.is_empty() {
                wanted.push((d.wallpaper_path.clone(), false));
            }
        }
        self.images
            .retain(|p, _| wanted.iter().any(|(path, _)| path == p));
        for (path, app) in wanted {
            if !self.images.contains_key(&path) {
                let image = if app {
                    self.cache.app_icon(&path, 64.0)
                } else {
                    self.cache.file(&path, 600.0, 2.0)
                };
                if self.headless {
                    let _ = image.wait();
                }
                self.images.insert(path, image);
            }
        }
    }
}

pub fn fixture() -> State {
    let mut s = State {
        headless: true,
        ..State::default()
    };
    let assets = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("assets");
    let apps = [
        ("Finder", "/System/Library/CoreServices/Finder.app"),
        (
            "Safari",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
        ),
        ("Notes", "/System/Applications/Notes.app"),
        ("Calendar", "/System/Applications/Calendar.app"),
        ("Messages", "/System/Applications/Messages.app"),
        ("Mail", "/System/Applications/Mail.app"),
    ];
    let tiles: Vec<_> = apps
        .iter()
        .enumerate()
        .map(|(i, (label, path))| Tile {
            id: i.to_string(),
            label: (*label).into(),
            path: (*path).into(),
            missing: false,
        })
        .collect();
    s.update(Snapshot {
        profiles: vec![
            Profile {
                id: "default".into(),
                name: "Everyday".into(),
                is_default: true,
                has_dock: true,
                wallpaper_path: assets.join("coast.svg").to_string_lossy().into(),
                wallpaper_name: "Coastal morning".into(),
                tiles: tiles.clone(),
                placement: "Crop".into(),
                ..Default::default()
            },
            Profile {
                id: "work".into(),
                name: "Deep work".into(),
                has_dock: true,
                wallpaper_path: assets.join("dusk.svg").to_string_lossy().into(),
                wallpaper_name: "Blue hour".into(),
                tiles: tiles[..3].to_vec(),
                placement: "Crop".into(),
                ..Default::default()
            },
            Profile {
                id: "quiet".into(),
                name: "After hours".into(),
                has_dock: true,
                wallpaper_path: assets.join("clay.svg").to_string_lossy().into(),
                wallpaper_name: "Warm horizon".into(),
                tiles: tiles[2..].to_vec(),
                placement: "Crop".into(),
                ..Default::default()
            },
        ],
        desktops: vec![
            Desktop {
                key: "one".into(),
                label: "Desktop 1".into(),
                display: "Built-in display".into(),
                current: true,
                profile_id: "default".into(),
                ..Default::default()
            },
            Desktop {
                key: "two".into(),
                label: "Desktop 2".into(),
                display: "Built-in display".into(),
                profile_id: "work".into(),
                ..Default::default()
            },
        ],
        active_profile: "default".into(),
        dock_status: "Everyday · Default".into(),
        wallpaper_status: "Everyday · Default".into(),
        focus: "No Focus profile".into(),
        focus_status: "Ready for Focus filters".into(),
        desktop: "Desktop 1".into(),
        can_resume: true,
        remember_edits: true,
        desktop_dock: true,
        dwell: 1.2,
        dock_precedence: "focusWins".into(),
        wallpaper_precedence: "focusWins".into(),
        automatic_updates: true,
        can_update: true,
        version: "0.3.0 · Rune preview".into(),
        spaces_available: true,
        ..Default::default()
    });
    s
}
