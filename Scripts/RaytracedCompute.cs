using Godot;
using System;
using System.Runtime.InteropServices;

public partial class RaytracedCompute : Node
{
    [Export] public RDShaderFile ShaderSource;

    // Your scene tree is: Raymarcher (this script) -> ../UI/OutputTexture
    [Export] public NodePath OutputTextureRectPath { get; set; } = "../UI/OutputTexture";

    [Export] public Vector2I Resolution { get; set; } = new Vector2I(960, 540);

    private RenderingDevice _rd;
    private Rid _shaderRid;
    private Rid _pipelineRid;

    private Rid _outputTexRid;

    private Rid _paramsBufferRid;
    private Rid _uniformSetRid;

    private TextureRect _output;
    private ImageTexture _imageTexture;

    private bool _ok;

    [StructLayout(LayoutKind.Sequential)]
    private struct Params
    {
        public Vector2 Resolution;
        public float Time;

        public Vector3 CamPos;
        public Vector3 CamForward;
        public Vector3 CamRight;
        public Vector3 CamUp;
        public float FovY;
    }

    public override void _Ready()
    {
        _output = GetNode<TextureRect>(OutputTextureRectPath);
        _rd = RenderingServer.GetRenderingDevice();

        if (ShaderSource == null)
        {
            GD.PushError("RaytracedCompute: ShaderSource is null. Assign the imported RDShaderFile for res://Shaders/Raytracing/raytracer.glsl");
            _ok = false;
            return;
        }

        CreateOutputTexture();
        CreateComputePipeline();
        CreateUniforms();
        SetupDisplay();

        _ok = _pipelineRid.IsValid && _uniformSetRid.IsValid && _outputTexRid.IsValid;
    }

    public override void _ExitTree()
    {
        if (_rd == null)
        {
            return;
        }

        FreeRid(ref _uniformSetRid);
        FreeRid(ref _paramsBufferRid);
        FreeRid(ref _outputTexRid);
        FreeRid(ref _pipelineRid);
        FreeRid(ref _shaderRid);
    }

    public override void _Process(double delta)
    {
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

        // Use RGBA8 for easy readback -> Image -> UI
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
            GD.PushError("RaytracedCompute: compute pipeline invalid. Check shader import errors and ensure raytracer.glsl starts with #[compute].");
        }
    }

    private void CreateUniforms()
    {
        Params p = MakeParams();
        byte[] bytes = StructToBytes(p);

        _paramsBufferRid = _rd.StorageBufferCreate((uint)bytes.Length, bytes);

        RDUniform u0 = new RDUniform();
        u0.UniformType = RenderingDevice.UniformType.Image;
        u0.Binding = 0;
        u0.AddId(_outputTexRid);

        RDUniform u1 = new RDUniform();
        u1.UniformType = RenderingDevice.UniformType.StorageBuffer;
        u1.Binding = 1;
        u1.AddId(_paramsBufferRid);

        _uniformSetRid = _rd.UniformSetCreate(new Godot.Collections.Array<RDUniform> { u0, u1 }, _shaderRid, 0);
    }

    private void DispatchCompute()
    {
        Params p = MakeParams();
        byte[] bytes = StructToBytes(p);
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
        _output.ExpandMode = TextureRect.ExpandModeEnum.IgnoreSize;
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
        Params p = new Params();
        p.Resolution = new Vector2(Resolution.X, Resolution.Y);
        p.Time = (float)Time.GetTicksMsec() * 0.001f;

        p.CamPos = new Vector3(0.0f, 0.0f, -3.0f);
        p.CamForward = new Vector3(0.0f, 0.0f, 1.0f);
        p.CamRight = new Vector3(1.0f, 0.0f, 0.0f);
        p.CamUp = new Vector3(0.0f, 1.0f, 0.0f);
        p.FovY = Mathf.DegToRad(60.0f);

        return p;
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

    private void FreeRid(ref Rid rid)
    {
        if (rid.IsValid)
        {
            _rd.FreeRid(rid);
            rid = default;
        }
    }
}