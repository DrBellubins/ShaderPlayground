using Godot;
using System;

public partial class CameraFly : Camera3D
{
    [Export] public float Speed = 4.0f;
    [Export] public float SprintMultiplier = 2.0f;

    [Export] public float MouseSensitivity = 0.0025f;
    [Export] public float MaxPitchDegrees = 89.0f;
    [Export] public bool CaptureMouseOnReady = true;

    private float _yaw;
    private float _pitch;
    
    public override void _Ready()
    {
        if (CaptureMouseOnReady)
        {
            Input.MouseMode = Input.MouseModeEnum.Captured;
        }

        Vector3 rot = Rotation;
        _pitch = rot.X;
        _yaw = rot.Y;
    }

    public override void _Input(InputEvent @event)
    {
        if (@event is InputEventMouseMotion motion)
        {
            if (Input.MouseMode != Input.MouseModeEnum.Captured)
            {
                return;
            }

            _yaw -= motion.Relative.X * MouseSensitivity;
            _pitch -= motion.Relative.Y * MouseSensitivity;

            float maxPitch = Mathf.DegToRad(MaxPitchDegrees);
            _pitch = Mathf.Clamp(_pitch, -maxPitch, maxPitch);

            Rotation = new Vector3(_pitch, _yaw, 0.0f);
        }

        if (@event is InputEventKey key && key.Pressed && key.Keycode == Key.Escape)
        {
            Input.MouseMode = Input.MouseModeEnum.Visible;
        }

        if (@event is InputEventMouseButton btn && btn.Pressed && btn.ButtonIndex == MouseButton.Left)
        {
            Input.MouseMode = Input.MouseModeEnum.Captured;
        }
    }

    public override void _Process(double delta)
    {
        float dt = (float)delta;

        var forwardBackInput = Input.GetAxis("forward", "backward");
        var leftRightInput = Input.GetAxis("left", "right");
        var upDownInput = Input.GetAxis("down", "up");
        var isSprinting = Input.IsActionPressed("sprint");

        var currentSpeed = Speed;

        if (isSprinting)
            currentSpeed *= SprintMultiplier;
        
        // Move in *local* space so forward follows where you look.
        Translate(new Vector3(0f, 0f, forwardBackInput * currentSpeed * dt));
        Translate(new Vector3(leftRightInput * currentSpeed * dt, 0f, 0f));
        Translate(new Vector3(0f, upDownInput * currentSpeed * dt, 0f));
    }
}