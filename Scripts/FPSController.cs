using Godot;

public partial class FPSController : RigidBody3D
{
    // Movement variables
    [Export] public float Speed = 500.0f;           // Higher value since we’re applying forces
    [Export] public float JumpImpulse = 5.0f;       // Impulse for jumping
    [Export] public float RunSpeedMult = 1.5f;      // Speed increase when running
    [Export] public float CrouchSpeedMult = 0.5f;   // Speed reduction when crouching
    [Export] public float MouseSensitivity = 0.2f;  // Mouse sensitivity multiplier
    [Export] public float JoystickSensitivity = 5f; // Joy sensitivity multiplier
    [Export] public float PlayerHeight = 2f;        // How high the player is
    [Export] public float CrouchHeight = 0.5f;      // How low the crouch height is
    [Export] public float AirControl = 0.3f;        // Reduced control in air
    [Export] public float Friction = 0.9f;          // Linear damping applied manually

    // Camera variables
    public Camera3D Camera;
    private float gravity = (float)ProjectSettings.GetSetting("physics/3d/default_gravity");

    // Player variables
    private RayCast3D groundRay;
    private CollisionShape3D collider;
    private Vector3 direction;
    private Vector2 moveInput = Vector2.Zero;
    private Vector2 lookInput = Vector2.Zero;
    private float horizontalRotation = 0.0f;
    private float verticalRotation = 0.0f;
    private float currentFriction;

    private bool canWalk = true;

    private bool isMoving = false;
    private bool isGrounded = false;
    private bool isRunning = false;
    private bool isCrouched = false;
    private bool isSliding = false;

    private bool cursorLocked = false;

    public override void _Ready()
    {
        Camera = GetNode<Camera3D>("Camera");
        groundRay = GetNode<RayCast3D>("GroundRay");
        collider = GetNode<CollisionShape3D>("Collider");

        Input.MouseMode = Input.MouseModeEnum.Captured;

        currentFriction = Friction;
    }

    public override void _Input(InputEvent @event)
    {
        // Capture the input from mouse
        if (@event is InputEventMouseMotion mouseMotion)
        {
            Ginput.IsUsingController = false;
            lookInput = mouseMotion.Relative;
        }
        
        if (@event is InputEventMouseButton mouseButton)
        {
            if (mouseButton.IsPressed() && mouseButton.ButtonIndex == MouseButton.Left)
            {
                cursorLocked = false;
                Input.MouseMode = Input.MouseModeEnum.Captured;
            }
        }

        // Capture the input from a gamepad
        if (@event is InputEventJoypadMotion)
            Ginput.IsUsingController = true;
    }

    public override void _Process(double delta)
    {
        // Handle camera rotation
        HandleCameraRotation((float)delta);

        Debug.Write($"grounded: {isGrounded}");
        Debug.Write($"running: {isRunning}");
        Debug.Write($"crouched: {isCrouched}");
        Debug.Write($"sliding: {isSliding}");
        Debug.Write($"using controller: {Ginput.IsUsingController}");
        Debug.Write($"{direction}");
        Debug.Write($"{moveInput}");
    }

    public override void _PhysicsProcess(double delta)
    {
        // Apply custom friction (RigidBody3D doesn’t slide naturally like CharacterBody3D)
        Vector3 velocity = LinearVelocity;
        velocity.X *= currentFriction;
        velocity.Z *= currentFriction;
        LinearVelocity = velocity;

        HandleBodyRotation();
        HandleMovement((float)delta);
        HandleSliding((float)delta);
        HandleCrouching((float)delta);
    }

    private void HandleMovement(float delta)
    {
        isGrounded = groundRay.IsColliding();

        moveInput = new Vector2(Ginput.MoveLeftRight(), Ginput.MoveForwardBackward());
        isMoving = moveInput != Vector2.Zero;

        direction = (Camera.GlobalTransform.Basis * new Vector3(moveInput.X, 0, moveInput.Y));

        // Ignore camera pitch
        direction.Y = 0f;

        // Only normalize direction if there's input, but preserve magnitude for force scaling
        float inputStrength = moveInput.Length();

        if (inputStrength > 0)
            direction = direction.Normalized();
        else
            direction = Vector3.Zero;

        // Toggle run on controllers, hold on keyboard
        if (!Ginput.IsUsingController)
            isRunning = Ginput.RunPressing;
        else if (Ginput.RunPressed && isMoving)
            isRunning = !isRunning;
        
        if (!isMoving)
            isRunning = false;

        float crouchModifier = isCrouched ? CrouchSpeedMult : 1.0f;
        float runModifier = (isRunning && !isCrouched) ? RunSpeedMult : 1.0f;
        float control = isGrounded ? 1.0f : AirControl;

        if (direction != Vector3.Zero && canWalk)
        {
            if (Ginput.IsUsingController)
                inputStrength = Mathf.Clamp(inputStrength, 0f, 1f);
            else
                inputStrength = 1f; // Bypass joy strength

            Vector3 force = direction * inputStrength * Speed * runModifier * crouchModifier * control * delta;
            ApplyCentralForce(force);
        }

        // Handle jump
        if (Ginput.JumpPressed && isGrounded && !isCrouched)
            ApplyCentralImpulse(new Vector3(0f, JumpImpulse, 0f));
    }

    private void HandleCrouching(float delta)
    {
        // Toggle crouch on controllers, hold on keyboard
        if (Ginput.CrouchPressed && isGrounded && !isSliding)
        {
            if (!Ginput.IsUsingController)
                isCrouched = true;
            else
                isCrouched = !isCrouched;
        }

        if (Ginput.CrouchReleased && !Ginput.IsUsingController)
            isCrouched = false;

        Crouch(false, delta);
    }

    private void HandleSliding(float delta)
    {
        // Toggle sliding state
        if (isRunning && Ginput.CrouchPressed && isGrounded)
        {
            isSliding = true;
            canWalk = false;
            currentFriction = 1f;
            LinearVelocity += new Vector3(LinearVelocity.X, 0f, LinearVelocity.Z);
        }

        if (Ginput.CrouchReleased)
        {
            isSliding = false;
            canWalk = true;
            currentFriction = Friction;
        }

        Crouch(true, delta);
    }

    // Crouching code is also used for sliding
    private void Crouch(bool sliding, float delta)
    {
        var check = sliding ? isSliding : isCrouched;

        // Smoothly adjust collider height
        float targetHeight = check ? CrouchHeight : PlayerHeight;

        // TODO: This is broken in jolt???
        //((CapsuleShape3D)collider.Shape).Height = Mathf.Lerp(((CapsuleShape3D)collider.Shape).Height, targetHeight, 10f * delta);
        ((CapsuleShape3D)collider.Shape).Height = targetHeight;

        // Adjust collision shape position to keep feet grounded
        float heightDifference = (PlayerHeight - ((CapsuleShape3D)collider.Shape).Height) / 2f;
        Vector3 targetPosition = new Vector3(0, heightDifference, 0);

        if (!check)
            Position -= targetPosition;

        // Adjust camera position
        float cameraTargetY = check ? (CrouchHeight / 2f) : (PlayerHeight / 2f); // Hack cause camera height is not same as crouch height
        Vector3 cameraPos = Camera.Position;
        cameraPos.Y = Mathf.Lerp(cameraPos.Y, cameraTargetY, 10f * delta);
        Camera.Position = cameraPos;
    }

    private void HandleCameraRotation(float delta)
    {
        if (cursorLocked)
            return;
        
        if (Ginput.IsUsingController)
        {
            var joyX = Input.GetJoyAxis(0, JoyAxis.RightX);
            var joyY = Input.GetJoyAxis(0, JoyAxis.RightY);

            // TODO: The delta multiplier could be dependant on average framerate...
            lookInput = new Vector2(joyX * JoystickSensitivity * (delta * 100f),
                joyY * JoystickSensitivity * (delta * 100f));
            
            // TODO: This probably shouldn't be hardcoded.
            float deadzone = 0.1f;

            // Setup deadzones 
            if (joyX < deadzone && joyX > -deadzone)
                lookInput.X = 0f;

            if (joyY < deadzone && joyY > -deadzone)
                lookInput.Y = 0f;

            Debug.Write($"look: {lookInput}");
            Debug.Write($"joystick: ({joyX}, {joyY})");
        }

        if (lookInput == Vector2.Zero)
            return;

        horizontalRotation -= lookInput.X * MouseSensitivity;

        verticalRotation -= lookInput.Y * MouseSensitivity;
        verticalRotation = Mathf.Clamp(verticalRotation, -89.0f, 89.0f);

        Camera.RotationDegrees = new Vector3(
            verticalRotation,
            horizontalRotation,
            0
        );

        lookInput = Vector2.Zero;
    }

    private void HandleBodyRotation()
    {
        if (lookInput == Vector2.Zero || cursorLocked)
            return;

        RotateY(Mathf.DegToRad(-lookInput.X * MouseSensitivity));
    }

    public override void _UnhandledInput(InputEvent @event)
    {
        if (@event.IsActionPressed("ui_cancel"))
        {
            Input.MouseMode = Input.MouseModeEnum.Visible;
            cursorLocked = true;
        }
    }
}