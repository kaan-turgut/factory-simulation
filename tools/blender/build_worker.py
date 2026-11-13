"""Builds one factory worker from the CC0 Quaternius base character and animation library.

Run: Blender -b --python build_worker.py   (settings come from environment variables)

The body mesh is reduced, cut along clean planes (boots, hem, vest, collar, wrists), and each
garment region is given its own flat material and pushed slightly off the skin so it reads as
baggy workwear. A hard cap is added. The library clips are attached on the same skeleton.
"""
import sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from common import *
import bmesh
import glob

GENDER = os.environ.get("GENDER", "male")          # male | female
SKIN = os.environ.get("SKIN", "")                  # "" keeps the pack's default skin texture
VEST = os.environ.get("VEST", "#e8a22a")
CAPC = os.environ.get("CAP", "#f2c84b")
OUTFILE = os.environ["OUTFILE"]
CLIPS = os.environ.get("CLIPS", "Idle_Loop,Walk_Loop,Push_Loop,PickUp_Table,Interact,Carry_Loop,Carry_Idle_Loop,Cart_Push_Loop").split(",")
TARGET_TRIS = int(os.environ.get("TARGET_TRIS", "3000"))
PREVIEW = os.environ.get("PREVIEW", "")

BOOT_TOP = 0.20
HEM = 1.04            # shirt hem / trouser waist
VEST_BOTTOM = 1.00
ARMPIT = 1.38
V_NECK = 1.505
COLLAR = 1.53
STRAP_IN, STRAP_OUT = 0.075, 0.175
VEST_SIDE = 0.215
WRIST = 0.706

COLORS = {
    "Trousers": ("#27323f", 0.85),
    "Shirt": ("#3b4c61", 0.85),
    "Boots": ("#1e2124", 0.7),
    "Gloves": ("#3a6fb6", 0.8),
    "Tint": ("#ffffff", 0.6),            # vest and cap: recoloured per role in the game
    "VestBand": ("#e6ecee", 0.35),
}
OFFSET = {"vest": 0.022, "vestband": 0.024, "boots": 0.020, "trousers": 0.018, "shirt": 0.012, "gloves": 0.009, "skin": 0.0}


def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexcol(h):
    h = h.lstrip("#")
    r, g, b = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return (lin(r), lin(g), lin(b), 1.0)


def make_material(name, color, rough):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.diffuse_color = hexcol(color)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = hexcol(color)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = 0.0
    return m


def tris(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def region_of_group(name):
    n = name.lower()
    if n.startswith(("hand_", "thumb", "index", "middle", "ring", "pinky")):
        return "gloves"
    if n.startswith(("foot_", "ball")):
        return "boots"
    if n.startswith(("thigh", "calf", "pelvis")):
        return "trousers"
    if n.startswith(("clavicle", "upperarm", "lowerarm")):
        return "shirt"
    if n.startswith("spine"):
        return "torso"
    return "skin"


reset()
bpy.context.scene.render.fps = 30
suffix = "Male" if GENDER == "male" else "Female"
chars = import_gltf(UBC + "/Base Characters/Godot - UE/Superhero_%s_FullBody.gltf" % suffix)
anims = import_gltf(UAL)

arm = [o for o in chars if o.type == "ARMATURE"][0]
lib_arm = [o for o in anims if o.type == "ARMATURE"][0]
for o in list(anims):
    if o.type == "MESH":
        bpy.data.objects.remove(o)
lib_arm.hide_set(True)
for o in [o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("Icosphere")]:
    bpy.data.objects.remove(o)
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
body = max(meshes, key=tris)
eyes = [o for o in meshes if o.name.startswith("Eyes")]
brows = [o for o in meshes if o.name.startswith("Eyebrows")]
print("BODY", body.name, "tris", tris(body))

# --- Smaller textures and optional skin tone -----------------------------------------
if SKIN:
    pattern = glob.escape(UBC + "/Base Characters/Textures/") + "T_Superhero_%s_%s*.png" % (suffix, SKIN)
    found = [f for f in glob.glob(pattern) if "Normal" not in f and "Rough" not in f]
    skin_mat = body.material_slots[0].material
    for node in skin_mat.node_tree.nodes:
        if node.type == "TEX_IMAGE" and node.image and not any(k in node.image.name for k in ("Normal", "Rough")):
            node.image = bpy.data.images.load(found[0])
            print("SKIN", found[0])
            break
for img in bpy.data.images:
    if img.size[0] > 512 and img.name.startswith(("T_Superhero", "T_Hair")):
        img.scale(512, 512)
    elif img.size[0] > 128 and img.name.startswith("T_Eye"):
        img.scale(128, 128)

# --- Reduce triangles ---------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
bpy.context.view_layer.objects.active = body
body.select_set(True)
mod = body.modifiers.new("Decimate", "DECIMATE")
mod.ratio = min(1.0, TARGET_TRIS / float(tris(body)))
mod.use_collapse_triangulate = True
bpy.ops.object.modifier_move_to_index(modifier="Decimate", index=0)
bpy.ops.object.modifier_apply(modifier="Decimate")
print("BODY after decimate", tris(body))
for e in eyes:
    bpy.context.view_layer.objects.active = e
    d = e.modifiers.new("Decimate", "DECIMATE")
    d.ratio = 0.18
    d.use_collapse_triangulate = True
    bpy.ops.object.modifier_move_to_index(modifier="Decimate", index=0)
    bpy.ops.object.modifier_apply(modifier="Decimate")

# --- Cut the body along clean planes so garment edges are straight ----------------------
bm = bmesh.new()
bm.from_mesh(body.data)
planes = [((0, 0, z), (0, 0, 1)) for z in (BOOT_TOP, VEST_BOTTOM, HEM, 1.08, 1.14, 1.24, 1.30, ARMPIT, V_NECK, COLLAR)]
for x in (STRAP_IN, STRAP_OUT, WRIST):
    planes += [((x, 0, 0), (1, 0, 0)), ((-x, 0, 0), (1, 0, 0))]
for co_, no_ in planes:
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], dist=1e-5, plane_co=co_, plane_no=no_)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.to_mesh(body.data)
bm.free()
for p in body.data.polygons:
    p.use_smooth = True
no_weights = sum(1 for v in body.data.vertices if len(v.groups) == 0)
print("BODY after cuts", tris(body), "vertices without weights:", no_weights)

# --- Garment regions ---------------------------------------------------------------
mats = {name: make_material(name, color, rough) for name, (color, rough) in COLORS.items()}
index = {}
for name in ["Trousers", "Shirt", "Boots", "Gloves", "Tint", "VestBand"]:
    body.data.materials.append(mats[name])
    index[name.lower()] = len(body.data.materials) - 1
index["vest"] = index["tint"]

names = {g.index: g.name for g in body.vertex_groups}
vertex_group_region = []
for v in body.data.vertices:
    score = {}
    for g in v.groups:
        r = region_of_group(names[g.group])
        score[r] = score.get(r, 0.0) + g.weight
    vertex_group_region.append(max(score, key=score.get) if score else "skin")

co = [body.matrix_world @ v.co for v in body.data.vertices]
face_region = []
counts = {}
for poly in body.data.polygons:
    verts = [co[i] for i in poly.vertices]
    c = sum(verts, mathutils.Vector((0, 0, 0))) / len(verts)
    regions = [vertex_group_region[i] for i in poly.vertices]
    r = max(set(regions), key=regions.count)
    ax = abs(c.x)
    if r == "boots" or (c.z < BOOT_TOP and r == "trousers"):
        region = "boots"
    elif r == "gloves":
        region = "gloves"
    elif VEST_BOTTOM <= c.z <= ARMPIT and ax <= VEST_SIDE:
        region = "vest"
        if 1.08 <= c.z <= 1.14 or 1.24 <= c.z <= 1.30:
            region = "vestband"
    elif ARMPIT < c.z <= V_NECK and ax < STRAP_OUT:
        region = "vest"
    elif V_NECK < c.z < 1.575 and STRAP_IN <= ax <= STRAP_OUT:
        region = "vest"
    elif r == "trousers":
        region = "trousers" if c.z < HEM else "shirt"
    elif r in ("torso", "shirt"):
        region = "skin" if (c.z >= COLLAR and ax < 0.125) else "shirt"
    else:
        region = "skin"
    face_region.append(region)
    counts[region] = counts.get(region, 0) + 1
    if region != "skin":
        poly.material_index = index[region]
print("REGIONS", counts)

# push garments off the skin along the vertex normals (no extra triangles)
vertex_offset = [0.0] * len(body.data.vertices)
for poly, region in zip(body.data.polygons, face_region):
    for i in poly.vertices:
        vertex_offset[i] = max(vertex_offset[i], OFFSET[region])
body.data.update()
for v, d in zip(body.data.vertices, vertex_offset):
    v.co = v.co + v.normal * d
body.data.update()

# --- Head measurements for the cap ----------------------------------------------------
head_points = [body.matrix_world @ v.co for v in body.data.vertices
               if any(names[g.group] == "Head" and g.weight > 0.6 for g in v.groups)]
hx = [p.x for p in head_points]; hy = [p.y for p in head_points]; hz = [p.z for p in head_points]
cx, cy = (min(hx) + max(hx)) / 2, (min(hy) + max(hy)) / 2
top = max(hz)
width = max(hx) - min(hx)
depth = max(hy) - min(hy)
print("HEAD x %.3f..%.3f y %.3f..%.3f z %.3f..%.3f" % (min(hx), max(hx), min(hy), max(hy), min(hz), top))


def mesh_from_bmesh(name, bm, material):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    me.materials.append(material)
    group = obj.vertex_groups.new(name="Head")
    group.add(list(range(len(me.vertices))), 1.0, "REPLACE")
    modifier = obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = arm
    obj.parent = arm
    for p in me.polygons:
        p.use_smooth = True
    return obj


bm = bmesh.new()
bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=10, radius=1.0)
for v in [v for v in bm.verts if v.co.z < 0.0]:
    bm.verts.remove(v)
rim_z = top - 0.095
for v in bm.verts:
    v.co.x = v.co.x * (width * 0.5 + 0.012) + cx
    v.co.y = v.co.y * (depth * 0.5 + 0.014) + cy + 0.006
    v.co.z = v.co.z * 0.125 + rim_z
cap = mesh_from_bmesh("Cap", bm, mats["Tint"])

bm = bmesh.new()
bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=6, radius=1.0)
for v in bm.verts:
    v.co.x = v.co.x * (width * 0.36) + cx
    v.co.y = v.co.y * (depth * 0.42) + cy - depth * 0.50
    v.co.z = v.co.z * 0.012 + rim_z + 0.004
for v in [v for v in bm.verts if v.co.y > cy - depth * 0.34]:
    bm.verts.remove(v)
brim = mesh_from_bmesh("CapBrim", bm, mats["Tint"])
print("TOTAL tris", tris(body))

# --- Cheaper to animate: fewer bones, a single mesh and one texture atlas -----------------
import numpy as np
FINGERS = ("thumb", "index", "middle", "ring", "pinky")

# 1. Fold the finger bones into the hands and delete them (65 bones -> 23).
fold = []
for v in body.data.vertices:
    for g in v.groups:
        n = names[g.group]
        if n.startswith(FINGERS) and n.endswith(("_l", "_r")):
            fold.append((v.index, "hand_" + n[-1], g.weight))
for index_, hand, weight in fold:
    body.vertex_groups[hand].add([index_], weight, "ADD")
for g in [g for g in body.vertex_groups if g.name.startswith(FINGERS) or g.name.startswith("ball_leaf")]:
    body.vertex_groups.remove(g)
bpy.ops.object.select_all(action="DESELECT")
bpy.context.view_layer.objects.active = arm
arm.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
for eb in [eb for eb in arm.data.edit_bones if eb.name.startswith(FINGERS) or eb.name.startswith("ball_leaf")]:
    arm.data.edit_bones.remove(eb)
bpy.ops.object.mode_set(mode="OBJECT")
print("BONES", len(arm.data.bones))

# 2. One atlas: skin (top-left), eye (next to it), flat colour swatches (bottom row).
def read_pixels(image):
    a = np.empty(len(image.pixels), dtype=np.float32)
    image.pixels.foreach_get(a)
    return a.reshape(image.size[1], image.size[0], 4)


skin_node = [n for n in body.material_slots[0].material.node_tree.nodes
             if n.type == "TEX_IMAGE" and n.image and not any(k in n.image.name for k in ("Normal", "Rough"))][0]
skin_pixels = read_pixels(skin_node.image)
eye_image = [i for i in bpy.data.images if i.name.startswith("T_Eye") and "Normal" not in i.name][0]
eye_pixels = read_pixels(eye_image)
ATLAS = 1024
atlas = np.ones((ATLAS, ATLAS, 4), dtype=np.float32)
atlas[:, :, :3] = 0.5
sw, sh = skin_pixels.shape[1], skin_pixels.shape[0]
atlas[ATLAS // 2:ATLAS // 2 + sh, 0:sw] = skin_pixels
ew, eh = eye_pixels.shape[1], eye_pixels.shape[0]
atlas[ATLAS // 2:ATLAS // 2 + eh, ATLAS // 2:ATLAS // 2 + ew] = eye_pixels
SWATCH = {"trousers": 0, "shirt": 1, "boots": 2, "gloves": 3, "vestband": 4}
for region, k in SWATCH.items():
    hexvalue = COLORS[region.capitalize() if region != "vestband" else "VestBand"][0].lstrip("#")
    # image pixels are stored sRGB-encoded, so the hex values go in unchanged
    atlas[0:16, 16 * k:16 * k + 16, :3] = [int(hexvalue[i:i + 2], 16) / 255 for i in (0, 2, 4)]
atlas_image = bpy.data.images.new("WorkerAtlas", ATLAS, ATLAS)
atlas_image.pixels.foreach_set(atlas.ravel())
atlas_image.pack()
atlas_material = bpy.data.materials.new("Atlas")
atlas_material.use_nodes = True
atlas_bsdf = atlas_material.node_tree.nodes["Principled BSDF"]
atlas_node = atlas_material.node_tree.nodes.new("ShaderNodeTexImage")
atlas_node.image = atlas_image
atlas_material.node_tree.links.new(atlas_node.outputs["Color"], atlas_bsdf.inputs["Base Color"])
atlas_bsdf.inputs["Roughness"].default_value = 0.75
atlas_bsdf.inputs["Metallic"].default_value = 0.0

# 3. Point every face at its atlas region and rebuild the material slots (atlas + tint).
uvs = body.data.uv_layers.active.data
for poly, region in zip(body.data.polygons, face_region):
    for li in poly.loop_indices:
        u, v = uvs[li].uv
        if region == "skin":
            uvs[li].uv = (u * 0.5, 0.5 + v * 0.5)
        elif region != "vest":
            k = SWATCH[region]
            uvs[li].uv = ((16 * k + 8) / ATLAS, 8.0 / ATLAS)
body.data.materials.clear()
body.data.materials.append(atlas_material)
body.data.materials.append(mats["Tint"])
for poly, region in zip(body.data.polygons, face_region):
    poly.material_index = 1 if region == "vest" else 0
for e in eyes:
    e_uvs = e.data.uv_layers.active.data
    for li in range(len(e_uvs)):
        u, v = e_uvs[li].uv
        e_uvs[li].uv = (0.5 + u * 0.125, 0.5 + v * 0.125)
    e.data.materials.clear()
    e.data.materials.append(atlas_material)
for o in brows:
    bpy.data.objects.remove(o)
brows = []
for extra in (cap, brim):
    extra.data.uv_layers.new(name="UVMap")

# 4. Join everything into one skinned mesh.
bpy.ops.object.select_all(action="DESELECT")
for o in [body, cap, brim] + eyes:
    o.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
body.name = "Worker"
print("WORKER mesh materials", [m.name for m in body.data.materials], "tris", tris(body))

# --- Carrying clips: a two-armed hold at the chest, authored on the same skeleton ----------
import re
CARRY_TARGET = {"l": mathutils.Vector((0.265, -0.30, 1.23)), "r": mathutils.Vector((-0.265, -0.30, 1.23))}
# Hands on a cart handle or pallet-jack grip: slightly lower, closer together, elbows down.
HANDLE_TARGET = {"l": mathutils.Vector((0.21, -0.30, 1.10)), "r": mathutils.Vector((-0.21, -0.30, 1.10))}
POLE = {"l": mathutils.Vector((0.9, 0.35, -0.5)), "r": mathutils.Vector((-0.9, 0.35, -0.5))}
CARRY_ROLL = float(os.environ.get("CARRY_ROLL", "0"))
HAND_BONES = ("thumb", "index", "middle", "ring", "pinky")


def aim(pb, direction, roll=0.0):
    current = pb.matrix.to_3x3()
    axis = (current @ mathutils.Vector((0, 1, 0))).normalized()
    swing = axis.rotation_difference(direction.normalized()).to_matrix()
    rotated = swing @ current
    if roll:
        rotated = mathutils.Matrix.Rotation(roll, 3, direction.normalized()) @ rotated
    m4 = rotated.to_4x4()
    m4.translation = pb.matrix.translation
    pb.matrix = m4
    bpy.context.view_layer.update()


def solve_carry(targets):
    arm.animation_data_create()
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    bpy.context.view_layer.update()
    result = {}
    for side in ("l", "r"):
        up, lo, hand = (arm.pose.bones["%s_%s" % (n, side)] for n in ("upperarm", "lowerarm", "hand"))
        shoulder = up.head.copy()
        l1 = (lo.head - up.head).length
        l2 = (hand.head - lo.head).length
        target = targets[side]
        reach = target - shoulder
        d = min(reach.length, l1 + l2 - 0.002)
        u = reach.normalized()
        a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
        h = max(0.0, l1 * l1 - a * a) ** 0.5
        pole = POLE[side] - u * POLE[side].dot(u)
        elbow = shoulder + u * a + pole.normalized() * h
        aim(up, elbow - shoulder)
        aim(lo, target - elbow, CARRY_ROLL if side == "l" else -CARRY_ROLL)
        aim(hand, target - elbow)
        for name in ("upperarm", "lowerarm", "hand"):
            pb = arm.pose.bones["%s_%s" % (name, side)]
            result[pb.name] = tuple(pb.rotation_quaternion)
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
    bpy.context.view_layer.update()
    return result


def carry_clip(source, name, rotations):
    action = bpy.data.actions[source].copy()
    action.name = name
    slot = list(action.slots)[0]
    bag = action.layers[0].strips[0].channelbag(slot)
    for fc in list(bag.fcurves):
        m = re.match(r'pose\.bones\["(.+?)"\]', fc.data_path)
        if m and m.group(1).startswith(("upperarm_", "lowerarm_", "hand_")):
            bag.fcurves.remove(fc)
    end = int(action.frame_range[1])
    for bone, q in rotations.items():
        for i in range(4):
            fc = bag.fcurves.new('pose.bones["%s"].rotation_quaternion' % bone, index=i, group_name=bone)
            for frame in (0, end):
                fc.keyframe_points.insert(frame, q[i])
    return action


carry = solve_carry(CARRY_TARGET)
carry_clip("Walk_Loop", "Carry_Loop", carry)
carry_clip("Idle_Loop", "Carry_Idle_Loop", carry)
carry_clip("Walk_Loop", "Cart_Push_Loop", solve_carry(HANDLE_TARGET))

# --- Preview renders, then the clips ------------------------------------------------------
if PREVIEW:
    render_setup()
    for clip in PREVIEW.split(","):
        name, frame = clip.split(":")
        play(arm, name, int(frame))
        if name.startswith("Carry"):
            sack = bpy.data.objects.get("PreviewSack")
            if sack is None:
                bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, -0.30, 1.23))
                sack = bpy.context.object
                sack.name = "PreviewSack"
                sack.scale = (0.5, 0.22, 0.28)
        for tag, loc in (("front", (0, -4.2, 1.0)), ("side", (4.2, 0, 1.0))):
            shoot("%s/%s_%s_%s.png" % (os.environ["OUT"], os.path.basename(OUTFILE)[:-4], name, tag), loc, (0, 0, 0.95), ortho=2.2)
    arm.animation_data.action = None
if os.environ.get("PREVIEW_ONLY") == "1":
    sys.exit(0)

arm.animation_data_create()
arm.animation_data.action = None
for name in CLIPS:
    action = bpy.data.actions[name]
    track = arm.animation_data.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, 0, action)
    if list(action.slots):
        strip.action_slot = list(action.slots)[0]

bpy.ops.object.select_all(action="DESELECT")
for o in [arm, body]:
    o.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.gltf(filepath=OUTFILE, export_format="GLB", use_selection=True,
                          export_animation_mode="NLA_TRACKS", export_skins=True, export_yup=True)
print("EXPORTED", OUTFILE, os.path.getsize(OUTFILE))
