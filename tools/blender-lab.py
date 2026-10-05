# Blender lighting lab for the archive array (headless: `pip install bpy`, Blender 4.2).
#   python3 tools/blender-lab.py B '{"samples":32,"world_strength":0.6,"strip":500000,"fog":0.002}'
# Variants: A sun from behind-left (web), B strip light left of the camera, C both, D strip behind-left.
# Renders go to $LAB_OUT (default ./lab-out). Used to work out the video look's lighting.
import bpy, sys, math, json, os
from mathutils import Vector
OUT = os.environ.get('LAB_OUT', './lab-out') + '/'
os.makedirs(OUT, exist_ok=True)
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
variant = sys.argv[1] if len(sys.argv) > 1 else 'A'
cfg = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
samples = cfg.get('samples', 48)

def G(x, y, z):   # glTF (y-up) -> Blender (z-up)
    return Vector((x, -z, y))

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = samples
scene.cycles.use_denoising = True
scene.render.resolution_x = 960; scene.render.resolution_y = 540
scene.view_settings.view_transform = 'Filmic' if 'Filmic' in [i.identifier for i in bpy.types.ColorManagedViewSettings.bl_rna.properties['view_transform'].enum_items] else 'AgX'
scene.view_settings.exposure = cfg.get('exposure', 0.0)

# --- card
bpy.ops.import_scene.gltf(filepath=os.path.join(ROOT, 'Resources/Models/archive-cassette.glb'))
parts = [o for o in bpy.context.scene.objects if o.type == 'MESH']
keep = {'Frosted_Polymer', 'Ivory_Edges', 'Optical_Diffuser', 'Titanium_Fasteners', 'Index_Inlay', 'Printed_Label'}
for o in parts:
    name = o.active_material.name.split('.')[0] if o.active_material else ''
    if name not in keep:
        bpy.data.objects.remove(o)
parts = [o for o in bpy.context.scene.objects if o.type == 'MESH']
bpy.ops.object.select_all(action='DESELECT')
for o in parts: o.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
card = bpy.context.view_layer.objects.active
card.name = 'Card'

def principled(mat, base, rough, transmission=0.0, ior=1.46, metallic=0.0):
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes): nt.nodes.remove(n)
    out = nt.nodes.new('ShaderNodeOutputMaterial'); p = nt.nodes.new('ShaderNodeBsdfPrincipled')
    nt.links.new(p.outputs[0], out.inputs[0])
    r, g, b = [int(base[i:i+2], 16) / 255 for i in (0, 2, 4)]
    def lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    p.inputs['Base Color'].default_value = (lin(r), lin(g), lin(b), 1)
    p.inputs['Roughness'].default_value = rough
    p.inputs['Metallic'].default_value = metallic
    p.inputs['IOR'].default_value = ior
    p.inputs['Transmission Weight'].default_value = transmission
    if transmission > 0 and cfg.get('subsurface', 0) > 0:
        p.inputs['Subsurface Weight'].default_value = cfg['subsurface']
        p.inputs['Subsurface Radius'].default_value = (1.0, 0.6, 0.3)
        p.inputs['Subsurface Scale'].default_value = cfg.get('sss_scale', 0.3)

frost_t = cfg.get('frost_t', 0.9); ivory_t = cfg.get('ivory_t', 0.6)
for slot in card.material_slots:
    m = slot.material; name = m.name.split('.')[0]
    if cfg.get('diag'):
        principled(m, {'Frosted_Polymer': 'ff2020', 'Ivory_Edges': '2040ff', 'Optical_Diffuser': '20c020'}.get(name, '808080'), 0.6); continue
    if name == 'Frosted_Polymer': principled(m, cfg.get('frost', 'fff7ed'), cfg.get('rough', 0.3), frost_t)
    elif name == 'Ivory_Edges': principled(m, cfg.get('ivory', 'f0e7df'), 0.35, ivory_t)
    elif name == 'Optical_Diffuser': principled(m, cfg.get('diffuser', 'e2dad4'), 0.7)
    elif name == 'Titanium_Fasteners': principled(m, 'c8c8c8', 0.25, metallic=0.9)
    elif name == 'Index_Inlay': principled(m, 'e4d6c5', 0.5)
    else: principled(m, 'eae5dc', 0.6)

# --- array: 9 lanes x 32 rows, spacing 5.2 (x) / 0.62 (z, glTF)
coll = bpy.data.collections.new('Array'); scene.collection.children.link(coll)
for lane in range(9):
    for row in range(32):
        o = card.copy(); o.data = card.data
        x = (lane - 2) * 5.2; z = (row - 15.5) * 0.62
        wave = 0.35 * math.sin(row * 0.45 + lane * 0.9) * cfg.get('wave', 1.0)
        o.location = G(x, wave, z)
        coll.objects.link(o)
bpy.data.objects.remove(card)

# floor
bpy.ops.mesh.primitive_plane_add(size=400, location=G(0, -0.05, 0))
floor = bpy.context.object
fm = bpy.data.materials.new('Floor'); principled(fm, cfg.get('floor', 'd8c9b9'), 0.95); floor.data.materials.append(fm)

# --- camera (engine browsing pose)
yaw, el = math.radians(59), math.radians(19)
d = Vector((-math.sin(yaw) * math.cos(el), math.sin(el), math.cos(yaw) * math.cos(el)))
det = cfg.get('detail', 0.0)
d = (d.lerp(Vector((-0.277, 0.238, 0.931)), det)).normalized()
aim = Vector((-1.091, -0.045, 0.481)); dist = cfg.get('dist', 140 * (1 - det) + 72 * det)
pos = aim + d * dist
cam = bpy.data.cameras.new('Cam'); cam_o = bpy.data.objects.new('Cam', cam); scene.collection.objects.link(cam_o)
cam_o.location = G(*pos)
look = G(*aim) - cam_o.location
cam_o.rotation_euler = look.to_track_quat('-Z', 'Y').to_euler()
span = 7.33 * (1 - det) + 5.9 * det; fov = 2 * math.atan(span / (2 * dist))
cam.sensor_fit = 'VERTICAL'; cam.sensor_height = 24
cam.lens = 24 / (2 * math.tan(fov / 2))
print('camera lens mm', cam.lens, 'fov deg', math.degrees(fov), 'pos', cam_o.location)
cam.clip_end = 1000
if cfg.get('dof', 0) > 0:
    cam.dof.use_dof = True; cam.dof.focus_distance = dist; cam.dof.aperture_fstop = cfg['dof']
scene.camera = cam_o

# --- world
w = bpy.data.worlds.new('W'); scene.world = w; w.use_nodes = True
bg = w.node_tree.nodes['Background']
wc = cfg.get('world', 'eae5e1'); r, g, b = [int(wc[i:i+2], 16) / 255 for i in (0, 2, 4)]
bg.inputs[0].default_value = (r ** 2.2, g ** 2.2, b ** 2.2, 1); bg.inputs[1].default_value = cfg.get('world_strength', 1.0)
if cfg.get('fog', 0) > 0:
    vs = w.node_tree.nodes.new('ShaderNodeVolumeScatter'); vs.inputs['Density'].default_value = cfg['fog']
    vs.inputs['Anisotropy'].default_value = 0.3
    w.node_tree.links.new(vs.outputs[0], w.node_tree.nodes['World Output'].inputs['Volume'])

# --- lights
def sun(direction, energy, color):
    l = bpy.data.lights.new('Sun', 'SUN'); l.energy = energy; l.color = color; l.angle = math.radians(cfg.get('sun_angle', 5))
    o = bpy.data.objects.new('Sun', l); scene.collection.objects.link(o)
    v = G(*direction)
    o.rotation_euler = (-v).to_track_quat('-Z', 'Y').to_euler()   # sun shines along -Z local
    return o
def area(position, target, size, size_y, energy, color):
    l = bpy.data.lights.new('Area', 'AREA'); l.shape = 'RECTANGLE'; l.size = size; l.size_y = size_y
    l.energy = energy; l.color = color
    o = bpy.data.objects.new('Area', l); scene.collection.objects.link(o)
    o.location = G(*position); look = G(*target) - o.location
    o.rotation_euler = look.to_track_quat('-Z', 'Y').to_euler()
    return o
warm = (1.0, 0.86, 0.66)
right = Vector((0, 1, 0)).cross(d).normalized()  # camera right in glTF space
up = d.cross(right).normalized()
if variant == 'A':      # web-like sun from behind-left-above
    sun((-6, 14, -5), cfg.get('sun', 4), (1, 0.95, 0.88))
elif variant == 'B':    # long strip light low on the camera's left, aimed across the array
    p = aim - right * cfg.get('sx', 60) + up * cfg.get('sy', -10) + d * cfg.get('sz', 40)
    area(tuple(p), tuple(aim + right * 20), cfg.get('strip_len', 80), cfg.get('strip_w', 3), cfg.get('strip', 60000), warm)
elif variant == 'C':    # strip from lower-left plus soft sun from behind
    p = aim - right * 60 - up * 10 + d * 40
    area(tuple(p), tuple(aim + right * 20), cfg.get('strip_len', 80), cfg.get('strip_w', 3), cfg.get('strip', 60000), warm)
    sun((-6, 14, -5), cfg.get('sun', 1.5), (1, 0.95, 0.88))
elif variant == 'D':    # strip behind-left (backlight), low
    p = aim - right * 50 - d * 60 + up * 5
    area(tuple(p), tuple(aim), cfg.get('strip_len', 80), cfg.get('strip_w', 3), cfg.get('strip', 60000), warm)

scene.render.filepath = OUT + f'render-{variant}-{cfg.get("tag","")}.png'
bpy.ops.render.render(write_still=True)
print('wrote', scene.render.filepath)
