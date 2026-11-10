//! The tray icon and its menu. Windows only, and unverified: written against the tray-icon API and not run on Windows.
//! It draws the entries the model gives and hands each choice to a callback the moment it is made.

use tray_icon::menu::{Menu, MenuEvent, MenuId, MenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use super::icon;
use super::model::{MenuAction, MenuEntry};
use crate::strings;

pub struct Tray {
    icon: TrayIcon,
    items: Vec<(MenuAction, MenuItem)>,
}

impl Tray {
    /// `on_choice` runs as soon as an entry is chosen. Reading the choices from the window's frame lost them: Windows never
    /// repaints a hidden window, so with the window hidden Quit did nothing and the host had to be killed.
    pub fn new(entries: &[MenuEntry], on_choice: impl Fn(MenuAction) + Send + Sync + 'static) -> Result<Self, String> {
        let menu = Menu::new();
        let mut items = Vec::with_capacity(entries.len());
        for entry in entries {
            let item = MenuItem::with_id(menu_id(entry.action), entry.label, entry.enabled, None);
            menu.append(&item).map_err(|error| error.to_string())?;
            items.push((entry.action, item));
        }
        let ids: Vec<(MenuAction, MenuId)> = items.iter().map(|(action, item)| (*action, item.id().clone())).collect();
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
            if let Some((action, _)) = ids.iter().find(|(_, id)| *id == event.id) {
                on_choice(*action);
            }
        }));
        let icon = Icon::from_rgba(icon::RGBA.to_vec(), icon::SIDE, icon::SIDE).map_err(|error| error.to_string())?;
        let icon = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_tooltip(strings::TOOLTIP)
            .with_icon(icon)
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self { icon, items })
    }

    pub fn update(&self, entries: &[MenuEntry], status_line: &str) {
        for entry in entries {
            if let Some((_, item)) = self.items.iter().find(|(action, _)| *action == entry.action) {
                item.set_text(entry.label);
                item.set_enabled(entry.enabled);
            }
        }
        // Tooltips are capped at 128 characters on Windows, so the status line is cut short rather than refused.
        let tooltip: String = format!("{}\n{status_line}", strings::TOOLTIP).chars().take(127).collect();
        let _shown = self.icon.set_tooltip(Some(tooltip));
    }
}

fn menu_id(action: MenuAction) -> MenuId {
    MenuId::new(format!("{action:?}"))
}
