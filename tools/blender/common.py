import bpy, math, mathutils, os

UBC = os.environ["UBC"]
UAL = os.environ["UAL"]

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def import_gltf(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]

def render_setup(width=900, height=900):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.render.resolution_x = width
    sc.render.resolution_y = height
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "TEXTURE"
    sc.display.shading.show_cavity = False
    sc.world = bpy.data.worlds.new("w") if not sc.world else sc.world
    sc.world.color = (0.55, 0.6, 0.65)
    sc.render.film_transparent = False
    return sc

def shoot(path, location, target, ortho=None, lens=50):
    sc = bpy.context.scene
    cam = bpy.data.objects.get("Cam")
    if cam is None:
        cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
        bpy.context.collection.objects.link(cam)
    sc.camera = cam
    cam.location = location
    direction = mathutils.Vector(target) - mathutils.Vector(location)
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    if ortho:
        cam.data.type = "ORTHO"; cam.data.ortho_scale = ortho
    else:
        cam.data.type = "PERSP"; cam.data.lens = lens
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def play(armature, action_name, frame):
    """Put an action on an armature (Blender 5 slotted actions) and set the frame."""
    action = bpy.data.actions[action_name]
    armature.animation_data_create()
    armature.animation_data.action = action
    slots = list(action.slots)
    if slots:
        armature.animation_data.action_slot = slots[0]
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
