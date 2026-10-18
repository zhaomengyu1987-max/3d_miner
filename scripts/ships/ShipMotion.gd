extends RefCounted
## Lightweight kinematic drive. World metres; ship forward is +X. One owner ticks it.
## Navigation and presentation are separate; no physics body or combat simulator.
var velocity := Vector3.ZERO
var max_speed := 72.0
var acceleration := 36.0
var turn_rate := 60.0 # degrees per second
var drive := 0.0
const REVERSE_RATIO := 0.5

func stop() -> void:
	velocity = Vector3.ZERO
	drive = 0.0

static func forward_basis(direction: Vector3) -> Basis:
	return Basis(Vector3.UP, atan2(-direction.z, direction.x))

func face(body: Node3D, direction: Vector3, delta: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.000001:
		return
	var current := body.global_basis.get_rotation_quaternion()
	var desired := forward_basis(flat).get_rotation_quaternion()
	var angle := current.angle_to(desired)
	if angle > 0.00001:
		body.global_basis = Basis(current.slerp(desired, minf(1.0, deg_to_rad(turn_rate) * delta / angle)))

func travel(body: Node3D, target: Vector3, delta: float, reverse := false) -> bool:
	var speed_limit := max_speed * (REVERSE_RATIO if reverse else 1.0)
	var accel := maxf(acceleration * (REVERSE_RATIO if reverse else 1.0), 0.001)
	# Small steps keep braking stable across frame-rate changes and accelerated tests.
	var remaining := maxf(0.0, delta)
	while remaining > 0.000001:
		var dt := minf(remaining, 1.0 / 60.0)
		remaining -= dt
		var offset := target - body.global_position
		var distance := offset.length()
		if distance < 0.05 and velocity.length() < accel * dt + 0.05:
			body.global_position = target
			stop()
			return true
		var direction := offset / distance if distance > 0.000001 else Vector3.ZERO
		var facing := -direction if reverse else direction
		var planar := Vector3(facing.x, 0.0, facing.z)
		var alignment := 1.0
		if planar.length_squared() > 0.000001:
			alignment = body.global_basis.x.dot(planar.normalized())
		# Brake before a substantial course change, then turn at rest. This prevents
		# chasing a point sideways while the hull is facing somewhere else.
		if alignment < cos(deg_to_rad(8.0)):
			velocity = velocity.move_toward(Vector3.ZERO, accel * dt)
			body.global_position += velocity * dt
			drive = 0.0
			if velocity.length() < 0.05:
				face(body, facing, dt)
			continue
		face(body, facing, dt)
		alignment = clampf(alignment, 0.0, 1.0)
		# A discrete braking bound avoids overshoot at low speeds.
		var braking := sqrt(2.0 * accel * distance + accel * accel * dt * dt) - accel * dt
		var desired_velocity := direction * minf(speed_limit * alignment, braking)
		var previous := velocity
		velocity = velocity.move_toward(desired_velocity, accel * dt)
		body.global_position += velocity * dt
		drive = clampf((velocity - previous).dot(body.global_basis.x) / (accel * dt), 0.0, 1.0)
	return false
