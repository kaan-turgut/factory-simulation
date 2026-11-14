"""Normalise downloaded vehicles and plants into small game-ready GLBs for the factory grounds.

For each asset: keep the listed objects, join them into one mesh, apply transforms, turn
vehicles so their headlights face the game's +Z (Blender -Y), scale to real size, put the
origin at the centre of the base, shrink textures and export to assets/site/<name>.glb.
The body paint of each vehicle is renamed `<name>_paint` so the game can recolour it.
Sources and licences are listed in CREDITS.md.

SRC=<folder with the downloaded .glb files, named by their Poly Pizza id> \
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
    --python tools/blender/build_site_props.py
"""
import bpy, bmesh, math, mathutils, os, random

SRC = os.environ["SRC"]
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "site")
MAX_TEXTURE = 512

# name: (source id, objects to keep or None for all, axis to measure, metres (None keeps the
#        source size), is a vehicle, body paint material or None)
# Axes are measured after turning: x = width, y = length, z = height. With axis "scale",
# metres is the scale factor itself (the tractor shares the box truck's scale).
ASSETS = {
    # Vehicles (Quaternius CC0, PuKkBuMXDD and J-Toastie CC-BY 3.0).
    "car_sedan": ("Cz6yDaUcM9", None, "y", 4.65, True, "Blue"),
    "car_hatchback": ("unqqkULtRU", None, "y", 4.05, True, "LightBlue"),
    "car_suv": ("xsMtZhBkxL", None, "y", 4.7, True, "White"),
    "car_sports": ("1mkmFkAz5v", None, "y", 4.45, True, "White"),
    "pickup": ("qn4grQgHm8", None, "y", 5.3, True, None),
    "van": ("BbRojf2v3H", None, "y", 4.9, True, "bodywork"),
    "box_truck": ("Fy3WI3uXNQ", None, "x", 2.45, True, "truck_base_colour"),
    "tractor_unit": ("Fy3WI3uXNQ", ["Truck", "FrontTires", "TruckTiresBack1", "TruckTiresBack2"],
        "scale", 2.45 / 1.68, True, "truck_base_colour"),
    # Plants, a bench and a lamp post (Quaternius CC0).
    "tree_oak_a": ("etFGNvsiFv", ["NormalTree_1"], "z", None, False, None),
    "tree_oak_b": ("etFGNvsiFv", ["NormalTree_2"], "z", None, False, None),
    "tree_oak_c": ("etFGNvsiFv", ["NormalTree_3"], "z", None, False, None),
    "tree_birch_a": ("R7qMWzb7nk", ["BirchTree_2"], "z", None, False, None),
    "tree_birch_b": ("R7qMWzb7nk", ["BirchTree_5"], "z", None, False, None),
    "tree_pine": ("79gmlLnweB", None, "z", None, False, None),
    "bush": ("ooG6CkLyE8", None, "z", None, False, None),
    "bush_flowers": ("U1ymDy8tbY", None, "z", None, False, None),
    "flowers_a": ("NBUxHir6FJ", ["Flower_1_Clump"], "z", None, False, None),
    "flowers_b": ("NBUxHir6FJ", ["Flower_4_Clump"], "z", None, False, None),
    "flower_group": ("hfPzQAedOe", None, "z", 0.9, False, None),
    "bench": ("jLxjFxFRpw", None, "x", 1.8, False, None),
    "street_light": ("nFwrlcLvM5", None, "z", 7.0, False, None),
}
FRONT_MARKERS = ("headlight", "front_light")
# Trees are thinned to keep the grounds cheap: (share of bark triangles kept by a collapse
# decimation, share of leaf cards kept, growth of each kept card so the crown stays full).
THIN = {
    "tree_oak_a": (0.2, 0.5, 1.3), "tree_oak_b": (0.2, 0.55, 1.3), "tree_oak_c": (0.2, 0.6, 1.25),
    "tree_birch_a": (0.2, 0.6, 1.25), "tree_birch_b": (0.25, 0.7, 1.2), "tree_pine": (0.3, 1.0, 1.0),
    "bush_flowers": (1.0, 0.6, 1.25),
}


def front_direction(obj):
    # Average position of the headlight faces, relative to the mesh centre, in the XY plane.
    names = [m.name.lower() if m else "" for m in obj.data.materials]
    marked = [i for i, n in enumerate(names) if any(k in n for k in FRONT_MARKERS)]
    centre = sum((v.co for v in obj.data.vertices), mathutils.Vector()) / len(obj.data.vertices)
    total = mathutils.Vector()
    count = 0
    for polygon in obj.data.polygons:
        if polygon.material_index in marked:
            total += polygon.center
            count += 1
    if count == 0:
        raise RuntimeError("%s has no headlight material" % obj.name)
    direction = total / count - centre
    direction.z = 0
    return direction


def thin(obj, bark_ratio, leaf_keep, grow):
    # Collapse the bark (all non-leaf faces) and drop a seeded share of the two-triangle leaf
    # cards, enlarging the rest about their centres.
    leaf = {i for i, m in enumerate(obj.data.materials) if m and ("lea" in m.name.lower())}
    if bark_ratio < 1.0:
        group = obj.vertex_groups.new(name="bark")
        bark = [v.index for v in obj.data.vertices]
        group.add(bark, 1.0, "REPLACE")
        for polygon in obj.data.polygons:
            if polygon.material_index in leaf:
                group.remove(list(polygon.vertices))
        modifier = obj.modifiers.new("thin", "DECIMATE")
        modifier.ratio = bark_ratio
        modifier.vertex_group = "bark"
        bpy.ops.object.modifier_apply(modifier="thin")
    if leaf_keep >= 1.0:
        return
    rng = random.Random(obj.name)
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    seen = set()
    drop = []
    for face in mesh.faces:
        if face.index in seen or face.material_index not in leaf:
            continue
        card = [face]
        seen.add(face.index)
        stack = [face]
        while stack:
            for edge in stack.pop().edges:
                for other in edge.link_faces:
                    if other.index not in seen:
                        seen.add(other.index)
                        card.append(other)
                        stack.append(other)
        if rng.random() > leaf_keep:
            drop.extend(card)
        else:
            verts = {v for f in card for v in f.verts}
            centre = sum((v.co for v in verts), mathutils.Vector()) / len(verts)
            for v in verts:
                v.co = centre + (v.co - centre) * grow
    bmesh.ops.delete(mesh, geom=drop, context="FACES")
    mesh.to_mesh(obj.data)
    mesh.free()


def build(name, source, keep, axis, metres, vehicle, paint):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, source + ".glb"))
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if keep is not None:
        meshes = [o for o in meshes if o.name in keep]
        if len(meshes) != len(keep):
            raise RuntimeError("%s: missing objects %s" % (name, keep))
    bpy.ops.object.select_all(action="DESELECT")
    for o in bpy.data.objects:
        o.select_set(o in meshes)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    for o in list(bpy.data.objects):
        if o is not obj:
            bpy.data.objects.remove(o)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if name in THIN:
        thin(obj, *THIN[name])
    if vehicle:
        # Snap the length to a horizontal axis, then turn the headlights to -Y.
        direction = front_direction(obj)
        angle = math.atan2(direction.y, direction.x)
        snapped = round(angle / (math.pi / 2)) * (math.pi / 2)
        obj.data.transform(mathutils.Matrix.Rotation(-math.pi / 2 - snapped, 4, "Z"))
    corners = [v.co for v in obj.data.vertices]
    lo = mathutils.Vector([min(c[i] for c in corners) for i in range(3)])
    hi = mathutils.Vector([max(c[i] for c in corners) for i in range(3)])
    size = hi - lo
    if metres is None:
        scale = 1.0
    elif axis == "scale":
        scale = metres
    else:
        scale = metres / size["xyz".index(axis)]
    pivot = mathutils.Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    for v in obj.data.vertices:
        v.co = (v.co - pivot) * scale
    obj.data.update()
    obj.name = obj.data.name = name
    used = {m.name for m in obj.data.materials if m}
    for image in bpy.data.images:
        if image.size[0] > MAX_TEXTURE:
            image.scale(MAX_TEXTURE, max(1, image.size[1] * MAX_TEXTURE // image.size[0]))
            image.pack()
    for index, image in enumerate(bpy.data.images):
        image.name = "%s_texture%d" % (name, index)
    found_paint = False
    for material in list(bpy.data.materials):
        if material.name not in used:
            continue
        if paint is not None and material.name == paint:
            material.name = "%s_paint" % name
            found_paint = True
        else:
            material.name = "%s_%s" % (name, material.name.replace(" ", "_").replace(".", "_"))
    if paint is not None and not found_paint:
        raise RuntimeError("%s: paint material %s not found" % (name, paint))
    os.makedirs(OUT, exist_ok=True)
    path = os.path.abspath(os.path.join(OUT, name + ".glb"))
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=False,
        export_animations=False, export_materials="EXPORT", export_image_format="AUTO")
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    print("SITE %s: %d triangles, %.2f x %.2f x %.2f m, %d materials" % (
        name, tris, size.x * scale, size.y * scale, size.z * scale, len(obj.data.materials)))


for key, spec in ASSETS.items():
    build(key, *spec)
