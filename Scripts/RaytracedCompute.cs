using Godot;
using System;
using System.Runtime.InteropServices;

public partial class RaytracedCompute : Node
{
    [Export] public Camera3D Camera;
    [Export] public DirectionalLight3D Sun;
    [Export] public RDShaderFile ShaderSource;
    [Export] public NodePath OutputTextureRectPath { get; set; } = "../UI/OutputTexture";
    [Export] public Vector2I Resolution { get; set; } = new Vector2I(960, 540);
    [Export] public float JitterSpeed = 100f;
    [Export] public float Radius = 0.01f;
    
    private RenderingDevice _rd;

    private Rid _shaderRid;
    private Rid _pipelineRid;

    private Rid _outputTexRid;

    private Rid _paramsBufferRid; // UniformBuffer
    private Rid _uniformSetRid;

    private TextureRect _output;
    private ImageTexture _imageTexture;

    private bool _ok;

    private float deltaTime = 0f;
    private float time = 0f;
    
    [StructLayout(LayoutKind.Sequential)]
    private struct Params
    {
        public Vector4 ResolutionTime;
        public Vector4 CamPosFov;
        public Vector4 CamForward;
        public Vector4 CamRight;
        public Vector4 CamUp;
        public Vector4 Runtime;
        public Vector4 SunDirection;
    }

    public override void _Ready()
    {
        _output = GetNode<TextureRect>(OutputTextureRectPath);
        _rd = RenderingServer.CreateLocalRenderingDevice();

        if (ShaderSource == null)
        {
            GD.PushError("RaytracedCompute: ShaderSource is null.");
            _ok = false;
            return;
        }

        CreateOutputTexture();
        CreateComputePipeline();
        CreateUniforms();
        SetupDisplay();

        _ok = _pipelineRid.IsValid && _uniformSetRid.IsValid && _outputTexRid.IsValid;
    }

    public override void _Process(double delta)
    {
        deltaTime = (float)delta;
        time += deltaTime;
        
        if (!_ok)
        {
            return;
        }

        DispatchCompute();
        UpdateDisplayFromGpu();
    }

    private void CreateOutputTexture()
    {
        RDTextureFormat tf = new RDTextureFormat();
        tf.Width = (uint)Resolution.X;
        tf.Height = (uint)Resolution.Y;
        tf.Depth = 1;
        tf.ArrayLayers = 1;
        tf.Mipmaps = 1;
        tf.TextureType = RenderingDevice.TextureType.Type2D;

        tf.Format = RenderingDevice.DataFormat.R8G8B8A8Unorm;
        tf.UsageBits =
            RenderingDevice.TextureUsageBits.StorageBit |
            RenderingDevice.TextureUsageBits.CanCopyFromBit;

        RDTextureView tv = new RDTextureView();
        Godot.Collections.Array<byte[]> initialData = new Godot.Collections.Array<byte[]>();

        _outputTexRid = _rd.TextureCreate(tf, tv, initialData);
    }

    private void CreateComputePipeline()
    {
        RDShaderSpirV spirv = ShaderSource.GetSpirV();
        _shaderRid = _rd.ShaderCreateFromSpirV(spirv);
        _pipelineRid = _rd.ComputePipelineCreate(_shaderRid);

        if (!_pipelineRid.IsValid)
        {
            GD.PushError("RaytracedCompute: compute pipeline invalid. Check shader import errors.");
        }
    }

    private void CreateUniforms()
    {
        Params _params = MakeParams();
        byte[] bytes = StructToBytes(_params);

        // IMPORTANT: shader uses `uniform Params { ... }`, so this must be a UniformBuffer.
        _paramsBufferRid = _rd.UniformBufferCreate((uint)bytes.Length, bytes);

        RDUniform u0 = new RDUniform();
        u0.UniformType = RenderingDevice.UniformType.Image;
        u0.Binding = 0;
        u0.AddId(_outputTexRid);

        RDUniform u1 = new RDUniform();
        u1.UniformType = RenderingDevice.UniformType.UniformBuffer;
        u1.Binding = 1;
        u1.AddId(_paramsBufferRid);

        _uniformSetRid = _rd.UniformSetCreate(new Godot.Collections.Array<RDUniform> { u0, u1 }, _shaderRid, 0);

        if (!_uniformSetRid.IsValid)
        {
            GD.PushError("RaytracedCompute: uniform set invalid.");
        }
    }

    private void DispatchCompute()
    {
        Params _params = MakeParams();
        byte[] bytes = StructToBytes(_params);

        _rd.BufferUpdate(_paramsBufferRid, 0, (uint)bytes.Length, bytes);

        long list = _rd.ComputeListBegin();
        _rd.ComputeListBindComputePipeline(list, _pipelineRid);
        _rd.ComputeListBindUniformSet(list, _uniformSetRid, 0);

        uint gx = (uint)((Resolution.X + 7) / 8);
        uint gy = (uint)((Resolution.Y + 7) / 8);

        _rd.ComputeListDispatch(list, gx, gy, 1);
        _rd.ComputeListEnd();

        _rd.Submit();
        _rd.Sync();
    }

    private void SetupDisplay()
    {
        Image img = Image.Create(Resolution.X, Resolution.Y, false, Image.Format.Rgba8);
        _imageTexture = ImageTexture.CreateFromImage(img);

        _output.Texture = _imageTexture;
        _output.StretchMode = TextureRect.StretchModeEnum.Scale;
    }

    private void UpdateDisplayFromGpu()
    {
        byte[] data = _rd.TextureGetData(_outputTexRid, 0);

        if (data == null || data.Length == 0)
        {
            return;
        }

        Image img = Image.CreateFromData(Resolution.X, Resolution.Y, false, Image.Format.Rgba8, data);
        _imageTexture.Update(img);
    }

    private Params MakeParams()
    {
        Params _params = new Params();

        _params.ResolutionTime = new Vector4(Resolution.X, Resolution.Y,
            Time.GetTicksMsec() * 0.001f, time);

        //Vector3 camPos = new Vector3(0.0f, 0.0f, -3.0f);
        Vector3 camPos = Camera.Position;
        
        _params.CamPosFov = new Vector4(camPos.X, camPos.Y, camPos.Z, Mathf.DegToRad(60.0f));

        //Vector3 forward = new Vector3(0.0f, 0.0f, 1.0f);
        //Vector3 right = new Vector3(1.0f, 0.0f, 0.0f);
        //Vector3 up = new Vector3(0.0f, 1.0f, 0.0f);
        
        Vector3 forward = -Camera.GlobalTransform.Basis.Z;
        Vector3 right = Camera.GlobalTransform.Basis.X;
        Vector3 up = Camera.GlobalTransform.Basis.Y;

        _params.CamForward = new Vector4(forward.X, forward.Y, forward.Z, 0.0f);
        _params.CamRight = new Vector4(right.X, right.Y, right.Z, 0.0f);
        _params.CamUp = new Vector4(up.X, up.Y, up.Z, 0.0f);

        _params.Runtime = new Vector4(JitterSpeed, Radius, 0.0f, 0.0f);

        var sunDir = Sun.GlobalBasis.Z;
        _params.SunDirection = new Vector4(sunDir.X, sunDir.Y, sunDir.Z, 0f);
        
        return _params;
    }

    private static byte[] StructToBytes<T>(T data) where T : struct
    {
        int size = Marshal.SizeOf<T>();
        byte[] arr = new byte[size];

        IntPtr ptr = Marshal.AllocHGlobal(size);

        try
        {
            Marshal.StructureToPtr(data, ptr, false);
            Marshal.Copy(ptr, arr, 0, size);
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }

        return arr;
    }
}