//! The window's look (Windows only). The palette is opacities of white on a near-black stage with one state blue, the same
//! rule as the phone and the Mac host (wiki/DESIGN.md): the picture on the phone is the only thing entitled to a colour.
//! Cards are outlined, never filled.

use eframe::egui::{
    self, Align, Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Layout, Margin, RichText, Sense, Stroke,
    TextStyle, Vec2,
};

pub const BACKDROP: Color32 = Color32::from_rgb(10, 10, 11);
pub const ACCENT: Color32 = Color32::from_rgb(10, 132, 255);
pub const DANGER: Color32 = Color32::from_rgb(250, 115, 102);
pub const SUCCESS: Color32 = Color32::from_rgb(92, 217, 140);

const INK: Color32 = Color32::from_rgb(240, 240, 241);
const MUTED: Color32 = Color32::from_rgb(158, 158, 160);
const FAINT: Color32 = Color32::from_rgb(119, 119, 121);
const HAIRLINE: Color32 = Color32::from_rgb(34, 34, 36);
const RAISED: Color32 = Color32::from_rgb(34, 34, 37);
const RAISED_HOVER: Color32 = Color32::from_rgb(48, 48, 52);
const RAISED_PRESSED: Color32 = Color32::from_rgb(62, 62, 67);

const SYSTEM_FONT: &str = "C:\\Windows\\Fonts\\segoeui.ttf";
const CARD_RADIUS: u8 = 14;
const CONTROL_RADIUS: u8 = 9;

pub fn apply(ctx: &egui::Context) {
    install_system_font(ctx);
    ctx.set_visuals(visuals());
    ctx.style_mut(|style| {
        style.spacing.item_spacing = Vec2::new(10.0, 10.0);
        style.spacing.button_padding = Vec2::new(16.0, 8.0);
        style.spacing.interact_size.y = 34.0;
        style.text_styles = [
            (TextStyle::Heading, FontId::new(22.0, FontFamily::Proportional)),
            (TextStyle::Body, FontId::new(14.5, FontFamily::Proportional)),
            (TextStyle::Button, FontId::new(14.5, FontFamily::Proportional)),
            (TextStyle::Small, FontId::new(12.5, FontFamily::Proportional)),
            (TextStyle::Monospace, FontId::new(14.0, FontFamily::Monospace)),
        ]
        .into();
    });
}

/// Segoe UI is on every Windows install and is what the rest of the system is drawn in. The built-in font is the fallback.
fn install_system_font(ctx: &egui::Context) {
    let Ok(bytes) = std::fs::read(SYSTEM_FONT) else {
        return;
    };
    let mut fonts = FontDefinitions::default();
    fonts.font_data.insert("system".to_owned(), std::sync::Arc::new(FontData::from_owned(bytes)));
    if let Some(family) = fonts.families.get_mut(&FontFamily::Proportional) {
        family.insert(0, "system".to_owned());
    }
    ctx.set_fonts(fonts);
}

fn visuals() -> egui::Visuals {
    let mut visuals = egui::Visuals::dark();
    visuals.panel_fill = BACKDROP;
    visuals.window_fill = BACKDROP;
    visuals.extreme_bg_color = BACKDROP;
    visuals.faint_bg_color = BACKDROP;
    visuals.window_stroke = Stroke::new(1.0_f32, HAIRLINE);
    visuals.selection.bg_fill = ACCENT;
    visuals.selection.stroke = Stroke::new(1.0_f32, Color32::WHITE);
    visuals.hyperlink_color = ACCENT;
    let radius = CornerRadius::same(CONTROL_RADIUS);
    let widgets = &mut visuals.widgets;
    widgets.noninteractive.bg_fill = BACKDROP;
    widgets.noninteractive.bg_stroke = Stroke::new(1.0_f32, HAIRLINE);
    widgets.noninteractive.fg_stroke = Stroke::new(1.0_f32, INK);
    for (state, fill) in [(&mut widgets.inactive, RAISED), (&mut widgets.hovered, RAISED_HOVER), (&mut widgets.active, RAISED_PRESSED)] {
        state.bg_fill = fill;
        state.weak_bg_fill = fill;
        state.bg_stroke = Stroke::new(1.0_f32, HAIRLINE);
        state.fg_stroke = Stroke::new(1.0_f32, Color32::WHITE);
        state.corner_radius = radius;
    }
    widgets.noninteractive.corner_radius = radius;
    widgets.open.corner_radius = radius;
    visuals
}

/// An outlined group. Filled cards turn the page, the card and its rows into three greys a few points apart.
pub fn card<R>(ui: &mut egui::Ui, add_contents: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::new()
        .stroke(Stroke::new(1.0_f32, HAIRLINE))
        .corner_radius(CornerRadius::same(CARD_RADIUS))
        .inner_margin(Margin::same(18))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            add_contents(ui)
        })
        .inner
}

pub fn title(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(17.0).strong().color(Color32::WHITE));
}

pub fn muted(text: &str) -> RichText {
    RichText::new(text).color(MUTED)
}

/// Secondary text under a control or a heading.
pub fn hint(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(12.5).color(FAINT));
}

pub fn primary_button(ui: &mut egui::Ui, text: &str) -> egui::Response {
    ui.add(egui::Button::new(RichText::new(text).strong().color(Color32::WHITE)).fill(ACCENT).stroke(Stroke::NONE))
}

pub fn status_dot(ui: &mut egui::Ui, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(10.0), Sense::hover());
    ui.painter().circle_filled(rect.center(), 4.5, color);
}

/// A title and its explanation on the left, a switch on the right. Returns whether the switch was flipped this frame.
pub fn switch_row(ui: &mut egui::Ui, value: &mut bool, label: &str, explanation: Option<&str>) -> bool {
    const SWITCH_WIDTH: f32 = 44.0;
    let mut changed = false;
    ui.horizontal_top(|ui| {
        let text_width = (ui.available_width() - SWITCH_WIDTH - ui.spacing().item_spacing.x).max(80.0);
        ui.allocate_ui_with_layout(Vec2::new(text_width, 0.0), Layout::top_down(Align::LEFT), |ui| {
            ui.set_width(text_width);
            ui.label(RichText::new(label).color(Color32::WHITE));
            if let Some(explanation) = explanation {
                hint(ui, explanation);
            }
        });
        ui.with_layout(Layout::right_to_left(Align::TOP), |ui| {
            changed = switch(ui, value).clicked();
        });
    });
    changed
}

fn switch(ui: &mut egui::Ui, value: &mut bool) -> egui::Response {
    let (rect, mut response) = ui.allocate_exact_size(Vec2::new(44.0, 26.0), Sense::click());
    if response.clicked() {
        *value = !*value;
        response.mark_changed();
    }
    let track = if *value { ACCENT } else { RAISED_HOVER };
    let painter = ui.painter();
    painter.rect_filled(rect, CornerRadius::same(13), track);
    let knob_x = if *value { rect.right() - 13.0 } else { rect.left() + 13.0 };
    painter.circle_filled(egui::pos2(knob_x, rect.center().y), 10.0, Color32::WHITE);
    response
}
