"""Normalise downloaded Poly Pizza props into small game-ready GLBs.

For each model: join all meshes into one, apply transforms, scale to its real size,
turn it so its front faces the game's +Z, put the origin at the centre of the base
(or the back face for wall-mounted items), shrink textures to at most 256 px and
export to assets/props/<name>.glb. Sources and licences are listed in CREDITS.md.

SRC=<folder with the downloaded .glb files> \
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
    --python tools/blender/build_safety_props.py
"""
import bpy, math, mathutils, os

SRC = os.environ["SRC"]
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "props")

# name: (source file, axis to measure, metres, turn about Z in degrees, wall mounted)
# The turn brings the model's front to Blender -Y, which glTF exports as +Z.
PROPS = {
    "fire_extinguisher": ("ext_jarlan.glb", "z", 0.62, 0, False),
    "water_cooler": ("cooler_toastie.glb", "z", 1.32, -90, False),
    "exit_sign": ("exit_toastie.glb", "x", 0.42, -90, True),
    "fire_alarm": ("alarm_google.glb", "z", 0.20, 0, True),
    "first_aid_kit": ("aid_q1.glb", "x", 0.42, 0, True),
    "wet_floor_sign": ("wetfloor_toastie.glb", "z", 0.62, -90, False),
    "traffic_cone": ("cone_q1.glb", "z", 0.5, 0, False),
}
MAX_TEXTURE = 256


def build(name, source, axis, metres, turn, wall):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, source))
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    # Unparent with world transforms kept, then join and bake the transform into the mesh.
    bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    for o in list(bpy.data.objects):
        if o is not obj:
            bpy.data.objects.remove(o)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.data.transform(mathutils.Matrix.Rotation(math.radians(turn), 4, "Z"))
    corners = [v.co for v in obj.data.vertices]
    lo = mathutils.Vector([min(c[i] for c in corners) for i in range(3)])
    hi = mathutils.Vector([max(c[i] for c in corners) for i in range(3)])
    size = hi - lo
    scale = metres / size["xyz".index(axis)]
    # Origin: centre of the base, or for wall items the middle of the back (+Y) face.
    if wall:
        pivot = mathutils.Vector(((lo.x + hi.x) / 2, hi.y, lo.z))
    else:
        pivot = mathutils.Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    for v in obj.data.vertices:
        v.co = (v.co - pivot) * scale
    obj.name = obj.data.name = name
    for index, image in enumerate(bpy.data.images):
        image.name = "%s_texture%d" % (name, index)
        if image.size[0] > MAX_TEXTURE:
            image.scale(MAX_TEXTURE, max(1, image.size[1] * MAX_TEXTURE // image.size[0]))
            image.pack()
    for material in bpy.data.materials:
        material.name = "%s_%s" % (name, material.name.replace(" ", "_"))
    os.makedirs(OUT, exist_ok=True)
    path = os.path.abspath(os.path.join(OUT, name + ".glb"))
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=False,
        export_animations=False, export_materials="EXPORT", export_image_format="AUTO")
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    print("PROP %s: %d triangles, %.2f x %.2f x %.2f m, %d materials" % (
        name, tris, size.x * scale, size.y * scale, size.z * scale, len(obj.data.materials)))


for key, spec in PROPS.items():
    build(key, *spec)
