using Godot;
using System;

public partial class CameraFly : Camera3D
{
    [Export] public float Speed;
    
    public override void _Ready()
    {
        
    }

    public override void _Process(double delta)
    {
        var forwardBackInput = Input.GetAxis("backward", "forward");
        var leftRightInput = Input.GetAxis("left", "right");

        Translate(new Vector3(0f, 0f, forwardBackInput * Speed * (float)delta));
        Translate(new Vector3(leftRightInput * Speed * (float)delta, 0f, 0f));
    }
}
