// iSurfSelect Inline Waterproof Marine Enclosure (Parametric OpenSCAD)
// Designed for Creality K2 Plus in unfilled ASA.
//
// Features:
//   - Port A (bottom wall -Y, left, x = -23):  Standard Deutsch DT04-4P ($1.70) + `clamp_dt04` U-fork
//   - Port B (bottom wall -Y, right, x = +23): Standard Deutsch DT06-4S ($2.11) + `clamp_dt06` U-bar
//   - Lid LED Light Pipes (+Z): 2x Bivar PLP2-500 ($0.74 ea) Ø3 mm polycarbonate light pipes
//       with flush outer lens recess, 2.0 mm press-fit web, internal sealant cup + anti-bleed
//       light chimneys, and first-layer debossed "PWR" / "CAN" labels.
//   - Top wall (+Y):    Waterproof SMA Female bulkhead (Ø6.6 mm with 6.05 mm D-flat)
//   - Right wall (+X):  M12x1.5 IP67/IP68 ePTFE breather vent (Bud IPV-67121-B)
//   - Lid Seal (+Z):    Continuous Ø2.5 mm silicone O-ring face seal with
//                       6x OUTBOARD M3 clamping bosses (zero screw holes inside seal)
//
// IMPORTANT BEFORE PRODUCTION RUN:
//   Pop your bare Waveshare ESP32-S3-RS485-CAN-U PCB out of its DIN shell, measure with calipers,
//   and update `pcb_hole_dx`, `pcb_hole_dy`, `led_pwr_pcb_xy`, and `led_can_pcb_xy` below.

$fn = 64;

/* [Render Selection] */
// "all" = body + lid + both U-clamps on one K2 Plus plate, or "body", "lid", "clamps"
part_to_render = "all";

/* [Enclosure Envelope (mm)] */
inner_w  = 100.0;  // X internal width
inner_l  = 118.0;  // Y internal length (40 mm wire/WAGO bay + 60 mm PCB + 18 mm RF coax)
inner_d  = 31.5;   // Z internal depth (tub_h = 35.0 mm -> leaves >10.5 mm solid wall above ports)
wall     = 5.5;    // 1.3 mm inner land + 2.9 mm O-ring groove + 1.3 mm outer land
floor_t  = 3.5;    // Bottom floor thickness
lid_t    = 5.5;    // Rigid lid thickness (total height = 40.5 mm)
corner_r = 9.0;

/* [O-Ring Face Seal (Ø2.5 mm Silicone Cord, ~24% squeeze)] */
oring_inner_land = 1.3;
oring_groove_w   = 2.9;
oring_groove_d   = 1.9;
tongue_h         = 1.5;

/* [Symmetric Port Centers on Bottom Wall (-Y)] */
port_x      = 23.0;  // Port A at -23 mm, Port B at +23 mm
dt_center_z = 15.0;  // Gives 5–6 mm solid wall below & >10.5 mm solid wall above cutouts

/* [Port A — Standard Deutsch DT04-4P (Inserts OUTSIDE -> INWARD)] */
dt04_recess_d    = 2.0;
dt04_shroud_w    = 21.30;
dt04_shroud_h    = 20.20;
dt04_pass_w      = 18.20;
dt04_pass_h      = 15.40;
dt04_moat_w      = 20.80;
dt04_moat_h      = 18.00;
dt04_boss_y      = 16.5;
dt04_neck_slot_w = 16.65;
dt04_clamp_dx    = 31.0;

/* [Port B — Standard Deutsch DT06-4S (Inserts INSIDE -> OUTWARD)] */
dt06_front_lip_t = 2.4;
dt06_nose_w      = 15.50;
dt06_nose_h      = 14.00;
dt06_latch_key_w = 10.80;
dt06_latch_top   = 9.45;  // z = 24.45 -> 10.55 mm solid top bridge below rim!
dt06_rear_w      = 18.65;
dt06_rear_h      = 18.85;
dt06_rear_len    = 6.90;
dt06_moat_extra  = 1.4;
dt06_moat_depth  = 3.6;
dt06_clamp_dx    = 31.0;
dt06_wire_slot_w = 13.2;

clamp_t          = 4.8;

/* [Top SMA Bulkhead & Side M12 Breather Vent] */
sma_z          = 18.0;
sma_d          = 6.6;
sma_d_flat     = 6.05;

vent_y         = 22.0;
vent_z         = 18.0;
vent_d         = 12.3;

/* [Outboard Lid M3 Clamping Bosses (CNC Kitchen / Ruthex M3x5.7 Inserts)] */
boss_out_d     = 11.0;
m3_insert_d    = 4.4;
m3_insert_h    = 6.5;
m3_clear_d     = 3.4;
m3_head_d      = 6.2;
m3_head_h      = 3.2;

/* [Waveshare Bare PCB Standoffs & LED Light-Pipe Coordinates — VERIFY WITH CALIPERS] */
pcb_center_y   = 17.0;   // Y center of bare PCB inside tub
pcb_hole_dx    = 82.0;   // Measure bare PCB X hole spacing and adjust
pcb_hole_dy    = 49.0;   // Measure bare PCB Y hole spacing and adjust
pcb_standoff_h = 5.0;
pcb_standoff_d = 8.0;

// LED XY offsets relative to PCB center (in assembled tub view: +X right, +Y toward SMA).
// Measure your Waveshare PWR & CAN LED centers relative to PCB center and update here!
enable_led_pipes  = true;
led_pwr_pcb_xy    = [-12.0, -8.0]; // [dx, dy] from PCB center for PWR LED
led_can_pcb_xy    = [ 12.0, -8.0]; // [dx, dy] from PCB center for CAN LED

// Bivar PLP2-500 (12.7 mm clear polycarbonate press-fit light pipe) geometry:
//   Lens head Ø3.3 x 0.8 mm, press-fit bore Ø2.92–3.00 mm over 2.0 mm panel web,
//   backed by internal sealant cup + anti-bleed light shroud chimney.
lp_head_recess_d  = 3.8;   // Flush guard recess for Ø3.3 mm lens head
lp_head_recess_h  = 0.9;
lp_press_bore_d   = 3.00;  // Bivar spec Ø2.92 +0.08 mm FDM tolerance
lp_press_web_h    = 2.0;   // Matches Bivar 1.2–2.36 mm panel thickness spec
lp_seal_bore_d    = 4.5;   // Internal step for adhesive/sealant bead around shaft
lp_chimney_od     = 7.6;   // Light-blocking shroud OD on underside of lid
lp_chimney_h      = 5.5;   // Guides 12.7 mm PLP2-500 down over PCB LED & blocks bleed
lp_label_depth    = 0.6;   // Crisp 3-layer debossed label on bed face

/* [External Locker Mounting Ears] */
ear_w          = 15.0;
ear_l          = 22.0;
ear_t          = 5.0;
ear_hole_d     = 5.5;
ear_offset_y   = 38.0;

outer_w = inner_w + 2 * wall; // 111.0 mm
outer_l = inner_l + 2 * wall; // 129.0 mm
tub_h   = floor_t + inner_d;  // 35.0 mm

dt06_boss_y = dt06_front_lip_t + dt06_rear_len; // 9.30 mm

function lid_screws() = [
    [-(outer_w/2 + 2.8), -(outer_l/2 - 14.0)],
    [ (outer_w/2 + 2.8), -(outer_l/2 - 14.0)],
    [-(outer_w/2 + 2.8), 0],
    [ (outer_w/2 + 2.8), 0],
    [-(outer_w/2 + 2.8),  (outer_l/2 - 14.0)],
    [ (outer_w/2 + 2.8),  (outer_l/2 - 14.0)]
];

// Assembled tub XY -> upside-down lid print XY (lid flips 180° around Y axis onto tub: X -> -X, Y -> +Y)
function lid_xy_for_pcb(pcb_xy) = [ -pcb_xy[0], pcb_center_y + pcb_xy[1] ];

module rounded_rect_2d(w, l, r) {
    offset(r = r)
        square([w - 2*r, l - 2*r], center = true);
}

module dt06_t_window_2d() {
    union() {
        hull() {
            for (sx = [-1, 1]) {
                translate([sx * (dt06_nose_w/2 - 2.0), -9.0 + 2.0])
                    circle(r = 2.0);
            }
            translate([0, 4.0])
                square([dt06_nose_w, 2.0], center = true);
        }
        hull() {
            translate([0, 2.5])
                square([dt06_latch_key_w, 1.0], center = true);
            for (sx = [-1, 1]) {
                translate([sx * (dt06_latch_key_w/2 - 1.4), dt06_latch_top - 1.4])
                    circle(r = 1.4);
            }
        }
    }
}

module body_with_lobes_2d() {
    union() {
        rounded_rect_2d(outer_w, outer_l, corner_r);
        for (pt = lid_screws()) {
            hull() {
                translate([pt[0], pt[1]])
                    circle(d = boss_out_d);
                translate([pt[0] > 0 ? outer_w/2 - 4 : -(outer_w/2 - 4), pt[1]])
                    square([4, boss_out_d + 4], center = true);
            }
        }
    }
}

module dual_dt_internal_bosses() {
    boss_w   = dt04_clamp_dx + 9.5;
    boss_top = dt_center_z + 13.0;

    translate([-port_x - boss_w/2, -outer_l/2 + wall - 0.5, floor_t])
        cube([boss_w, dt04_boss_y - wall + 0.5, boss_top - floor_t]);

    translate([port_x - boss_w/2, -outer_l/2 + wall - 0.5, floor_t])
        cube([boss_w, dt06_boss_y - wall + 0.5, boss_top - floor_t]);
}

module dt04_regular_cutout() {
    translate([0, dt04_recess_d / 2 - 0.5, 0])
        rotate([90, 0, 0])
            linear_extrude(height = dt04_recess_d + 1.0, center = true)
                rounded_rect_2d(dt04_shroud_w, dt04_shroud_h, 3.2);

    translate([0, (dt04_boss_y + 2) / 2, 0])
        rotate([90, 0, 0])
            linear_extrude(height = dt04_boss_y + 4.0, center = true)
                rounded_rect_2d(dt04_pass_w, dt04_pass_h, 2.8);

    translate([0, dt04_boss_y - 2.4, 0])
        rotate([90, 0, 0])
            linear_extrude(height = 5.2, center = true)
                rounded_rect_2d(dt04_moat_w, dt04_moat_h, 3.2);

    for (sx = [-1, 1]) {
        translate([sx * dt04_clamp_dx / 2, dt04_boss_y - m3_insert_h, 0])
            rotate([-90, 0, 0])
                cylinder(d = m3_insert_d, h = m3_insert_h + 0.6);
    }
}

module dt06_regular_cutout() {
    translate([0, dt06_front_lip_t / 2, 0])
        rotate([90, 0, 0])
            linear_extrude(height = dt06_front_lip_t + 2.0, center = true)
                dt06_t_window_2d();

    pocket_len = dt06_rear_len + 1.0;
    translate([0, dt06_front_lip_t + pocket_len / 2, 0])
        rotate([90, 0, 0])
            linear_extrude(height = pocket_len, center = true)
                rounded_rect_2d(dt06_rear_w, dt06_rear_h, 2.6);

    translate([0, dt06_boss_y - dt06_moat_depth / 2 + 0.2, 0])
        rotate([90, 0, 0])
            linear_extrude(height = dt06_moat_depth + 0.4, center = true)
                rounded_rect_2d(dt06_rear_w + 2 * dt06_moat_extra,
                                dt06_rear_h + 2 * dt06_moat_extra,
                                3.4);

    for (sx = [-1, 1]) {
        translate([sx * dt06_clamp_dx / 2, dt06_boss_y - m3_insert_h, 0])
            rotate([-90, 0, 0])
                cylinder(d = m3_insert_d, h = m3_insert_h + 0.6);
    }
}

module clamp_dt04() {
    cw = dt04_clamp_dx + 9.5;
    ch = 21.0;
    difference() {
        linear_extrude(height = clamp_t)
            rounded_rect_2d(cw, ch, 3.2);

        translate([0, -2.5, -0.5])
            linear_extrude(height = clamp_t + 1)
                rounded_rect_2d(dt04_neck_slot_w, 15.5, 2.0);
        translate([0, -ch/2, -0.5])
            linear_extrude(height = clamp_t + 1)
                square([dt04_neck_slot_w, ch], center = true);

        for (sx = [-1, 1]) {
            translate([sx * dt04_clamp_dx / 2, 0, -0.5])
                cylinder(d = m3_clear_d, h = clamp_t + 1);
        }
    }
}

module clamp_dt06() {
    cw = dt06_clamp_dx + 9.5;
    ch = 21.0;
    difference() {
        linear_extrude(height = clamp_t)
            rounded_rect_2d(cw, ch, 3.2);

        translate([0, 0, -0.5])
            cylinder(d = dt06_wire_slot_w, h = clamp_t + 1);
        translate([0, -ch/2, -0.5])
            linear_extrude(height = clamp_t + 1)
                square([dt06_wire_slot_w, ch], center = true);

        for (sx = [-1, 1]) {
            translate([sx * dt06_clamp_dx / 2, 0, -0.5])
                cylinder(d = m3_clear_d, h = clamp_t + 1);
        }
    }
}

module sma_d_hole() {
    rotate([90, 0, 0])
        linear_extrude(height = wall * 4, center = true)
            intersection() {
                circle(d = sma_d);
                translate([0, -(sma_d - sma_d_flat)/2])
                    square([sma_d + 1, sma_d_flat], center = true);
            }
}

module mounting_ears() {
    for (sx = [-1, 1], sy = [-1, 1]) {
        translate([sx * (outer_w/2 + ear_w/2 + 1), sy * ear_offset_y, 0]) {
            difference() {
                hull() {
                    translate([-sx * (ear_w/2), 0, ear_t/2])
                        cube([6, ear_l, ear_t], center = true);
                    translate([sx * (ear_w/2 - 5), 0, 0])
                        cylinder(r = 5.5, h = ear_t);
                }
                translate([sx * 2.5, 0, -1])
                    cylinder(d = ear_hole_d, h = ear_t + 2);
            }
        }
    }
}

// Stepped waterproof bore + debossed label for one Bivar PLP2-500 light pipe on `enclosure_lid`
module light_pipe_cutout(pt, label_txt) {
    translate([pt[0], pt[1], 0]) {
        // 1. Flush lens recess on outer lid face (z = 0 .. 0.9 mm)
        translate([0, 0, -0.05])
            cylinder(d = lp_head_recess_d, h = lp_head_recess_h + 0.05);

        // 2. Precision 2.0 mm press-fit web (z = 0.9 .. 2.9 mm)
        translate([0, 0, lp_head_recess_h - 0.1])
            cylinder(d = lp_press_bore_d, h = lp_press_web_h + 0.2);

        // 3. Internal sealant cup & light-shroud bore (z = 2.9 .. lid_t + lp_chimney_h)
        translate([0, 0, lp_head_recess_h + lp_press_web_h])
            cylinder(d = lp_seal_bore_d, h = lid_t + lp_chimney_h);

        // 4. First-layer debossed label below lens (X-mirrored so it reads forward when lid flips!)
        translate([0, -5.2, -0.05])
            linear_extrude(height = lp_label_depth + 0.05)
                mirror([1, 0, 0])
                    text(label_txt, size = 3.4, font = "Liberation Sans:style=Bold",
                         halign = "center", valign = "center");
    }
}

module enclosure_body() {
    inner_r = max(2.0, corner_r - wall);
    groove_in_w  = inner_w + 2 * oring_inner_land;
    groove_in_l  = inner_l + 2 * oring_inner_land;
    groove_in_r  = inner_r + oring_inner_land;
    groove_out_w = groove_in_w + 2 * oring_groove_w;
    groove_out_l = groove_in_l + 2 * oring_groove_w;
    groove_out_r = groove_in_r + oring_groove_w;

    difference() {
        union() {
            difference() {
                union() {
                    linear_extrude(height = tub_h)
                        body_with_lobes_2d();
                    mounting_ears();
                }
                translate([0, 0, floor_t])
                    linear_extrude(height = inner_d + 1)
                        rounded_rect_2d(inner_w, inner_l, inner_r);
            }
            dual_dt_internal_bosses();
        }

        translate([0, 0, tub_h - oring_groove_d])
            linear_extrude(height = oring_groove_d + 0.5)
                difference() {
                    rounded_rect_2d(groove_out_w, groove_out_l, groove_out_r);
                    rounded_rect_2d(groove_in_w, groove_in_l, groove_in_r);
                }

        for (pt = lid_screws()) {
            translate([pt[0], pt[1], tub_h - m3_insert_h])
                cylinder(d = m3_insert_d, h = m3_insert_h + 0.5);
        }

        translate([-port_x, -outer_l/2, dt_center_z])
            dt04_regular_cutout();

        translate([port_x, -outer_l/2, dt_center_z])
            dt06_regular_cutout();

        translate([0, outer_l/2 - wall/2, sma_z])
            sma_d_hole();

        translate([outer_w/2 - wall/2, vent_y, vent_z])
            rotate([0, 90, 0])
                cylinder(d = vent_d, h = wall * 4, center = true);
    }

    for (sx = [-1, 1], sy = [-1, 1]) {
        translate([sx * pcb_hole_dx/2, pcb_center_y + sy * pcb_hole_dy/2, floor_t]) {
            difference() {
                cylinder(d1 = pcb_standoff_d + 2, d2 = pcb_standoff_d, h = pcb_standoff_h);
                translate([0, 0, 0.8])
                    cylinder(d = m3_insert_d, h = pcb_standoff_h);
            }
        }
    }
}

module enclosure_lid() {
    inner_r = max(2.0, corner_r - wall);
    pwr_pt  = lid_xy_for_pcb(led_pwr_pcb_xy);
    can_pt  = lid_xy_for_pcb(led_can_pcb_xy);

    difference() {
        union() {
            linear_extrude(height = lid_t)
                body_with_lobes_2d();

            translate([0, 0, lid_t])
                linear_extrude(height = tongue_h)
                    difference() {
                        rounded_rect_2d(inner_w - 0.5, inner_l - 0.5, max(1.5, inner_r - 0.25));
                        rounded_rect_2d(inner_w - 4.5, inner_l - 4.5, max(1.0, inner_r - 2.25));
                    }

            // Internal anti-bleed light-shroud chimneys on underside of lid
            if (enable_led_pipes) {
                for (pt = [pwr_pt, can_pt]) {
                    translate([pt[0], pt[1], lid_t])
                        cylinder(d = lp_chimney_od, h = lp_chimney_h);
                }
            }
        }

        for (pt = lid_screws()) {
            translate([pt[0], pt[1], -0.5])
                cylinder(d = m3_clear_d, h = lid_t + tongue_h + 1);
            translate([pt[0], pt[1], -0.05])
                cylinder(d = m3_head_d, h = m3_head_h);
        }

        if (enable_led_pipes) {
            light_pipe_cutout(pwr_pt, "PWR");
            light_pipe_cutout(can_pt, "CAN");
        }
    }
}

if (part_to_render == "body") {
    enclosure_body();
} else if (part_to_render == "lid") {
    enclosure_lid();
} else if (part_to_render == "clamps") {
    translate([-24, 0, 0]) clamp_dt04();
    translate([ 24, 0, 0]) clamp_dt06();
} else {
    // Complete 4-piece print plate for Creality K2 Plus (350x350 mm bed)
    translate([-(outer_w/2 + 24), 0, 0])
        enclosure_body();
    translate([ (outer_w/2 + 24), 16, 0])
        enclosure_lid();
    translate([ (outer_w/2 - 2), -(outer_l/2 + 8), 0])
        clamp_dt04();
    translate([ (outer_w/2 + 48), -(outer_l/2 + 8), 0])
        clamp_dt06();
}
