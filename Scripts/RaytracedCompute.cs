using Godot;
using System;
using System.Runtime.InteropServices;

public partial class RaytracedCompute : Node
{
    [Export] public RDShaderFile ShaderSource;

    [Export] public NodePath OutputTextureRectPath { get; set; }

    [Export] public Vector2I Resolution { get; set; } = new Vector2I(960, 540);

    private RenderingDevice _rd;
    private Rid _shaderRid;
    private Rid _pipelineRid;

    private Rid _outputTexRid;

    private Rid _paramsBufferRid;
    private Rid _uniformSetRid;

    private TextureRect _output;
    private ImageTexture _imageTexture;

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

        CreateOutputTexture();
        CreateComputePipeline();
        CreateUniforms();
        SetupDisplay();
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
        if (_rd == null)
        {
            return;
        }

        DispatchCompute((float)delta);

        // Minimal display path: GPU -> CPU -> ImageTexture (slow but simple)
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
        tf.Format = RenderingDevice.DataFormat.R16G16B16A16Sfloat;
        tf.UsageBits =
            RenderingDevice.TextureUsageBits.StorageBit |
            RenderingDevice.TextureUsageBits.CanCopyFromBit;

        RDTextureView tv = new RDTextureView();

        // Godot C# expects Godot.Collections.Array<byte[]>
        Godot.Collections.Array<byte[]> initialData = new Godot.Collections.Array<byte[]>();

        _outputTexRid = _rd.TextureCreate(tf, tv, initialData);
    }

    private void CreateComputePipeline()
    {
        if (ShaderSource == null)
        {
            GD.PushError("ShaderSource is null. Assign the RDShaderFile that imports Shaders/Raytracing/raytracer.glsl.");
            return;
        }

        RDShaderSpirV spirv = ShaderSource.GetSpirV();

        _shaderRid = _rd.ShaderCreateFromSpirV(spirv);
        _pipelineRid = _rd.ComputePipelineCreate(_shaderRid);
    }

    private void CreateUniforms()
    {
        Params p = new Params();
        p.Resolution = new Vector2(Resolution.X, Resolution.Y);
        p.Time = 0.0f;

        p.CamPos = new Vector3(0.0f, 0.0f, -3.0f);
        p.CamForward = new Vector3(0.0f, 0.0f, 1.0f);
        p.CamRight = new Vector3(1.0f, 0.0f, 0.0f);
        p.CamUp = new Vector3(0.0f, 1.0f, 0.0f);
        p.FovY = Mathf.DegToRad(60.0f);

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

    private void DispatchCompute(float delta)
    {
        Params p = new Params();
        p.Resolution = new Vector2(Resolution.X, Resolution.Y);
        p.Time = (float)Time.GetTicksMsec() * 0.001f;

        p.CamPos = new Vector3(0.0f, 0.0f, -3.0f);
        p.CamForward = new Vector3(0.0f, 0.0f, 1.0f);
        p.CamRight = new Vector3(1.0f, 0.0f, 0.0f);
        p.CamUp = new Vector3(0.0f, 1.0f, 0.0f);
        p.FovY = Mathf.DegToRad(60.0f);

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
        // Readback from GPU. Then convert to RGBA8 for UI.
        // Godot returns an Image in the texture's format.
        Image img = _rd.TextureGetData(_outputTexRid, 0);

        if (img == null)
        {
            return;
        }

        if (img.GetFormat() != Image.Format.Rgba8)
        {
            img.Convert(Image.Format.Rgba8);
        }

        _imageTexture.Update(img);
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