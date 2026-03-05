using Godot;
using System;
using System.Runtime.InteropServices;

public partial class RaytracedCompute : Node
{
    [Export]
    public NodePath OutputTextureRectPath { get; set; }

    [Export]
    public Vector2I Resolution { get; set; } = new Vector2I(960, 540);

    private RenderingDevice _rd;
    private Rid _shaderRid;
    private Rid _pipelineRid;

    private Rid _outputTexRid;
    private Rid _outputTexViewRid;

    private Rid _paramsBufferRid;
    private Rid _uniformSetRid;

    private Texture2D _displayTexture;

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

        FreeRid(ref _outputTexViewRid);
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
    }

    private void CreateOutputTexture()
    {
        var tf = new RDTextureFormat();
        tf.Width = (uint)Resolution.X;
        tf.Height = (uint)Resolution.Y;
        tf.Depth = 1;
        tf.ArrayLayers = 1;
        tf.Mipmaps = 1;
        tf.TextureType = RenderingDevice.TextureType.Type2D;
        tf.Format = RenderingDevice.DataFormat.R16G16B16A16Sfloat;
        tf.UsageBits =
            RenderingDevice.TextureUsageBits.StorageBit |
            RenderingDevice.TextureUsageBits.CanUpdateBit |
            RenderingDevice.TextureUsageBits.SamplingBit |
            RenderingDevice.TextureUsageBits.CanCopyFromBit;

        var tv = new RDTextureView();

        _outputTexRid = _rd.TextureCreate(tf, tv, Array.Empty<byte[]>());
        _outputTexViewRid = _rd.TextureCreateSharedView(_outputTexRid, tv);
    }

    private void CreateComputePipeline()
    {
        // You must create an RDShaderFile resource in the editor that points to raytrace_sdf.compute.glsl
        // and assign it to this script or load it here. Keeping it minimal: load from res://
        var shaderFile = GD.Load<RDShaderFile>("res://raytrace_sdf.compute.glsl");
        var spirv = shaderFile.GetSpirV();

        _shaderRid = _rd.ShaderCreateFromSpirV(spirv);
        _pipelineRid = _rd.ComputePipelineCreate(_shaderRid);
    }

    private void CreateUniforms()
    {
        var p = new Params();
        p.Resolution = new Vector2(Resolution.X, Resolution.Y);
        p.Time = 0.0f;

        p.CamPos = new Vector3(0.0f, 0.0f, 0.0f);
        p.CamForward = new Vector3(0.0f, 0.0f, 1.0f);
        p.CamRight = new Vector3(1.0f, 0.0f, 0.0f);
        p.CamUp = new Vector3(0.0f, 1.0f, 0.0f);
        p.FovY = Mathf.DegToRad(60.0f);

        byte[] bytes = StructToBytes(p);

        _paramsBufferRid = _rd.StorageBufferCreate((uint)bytes.Length, bytes);

        var u0 = new RDUniform();
        u0.UniformType = RenderingDevice.UniformType.Image;
        u0.Binding = 0;
        u0.AddId(_outputTexViewRid);

        var u1 = new RDUniform();
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

        // Very simple camera (static). If you want: pull from a Camera3D node.
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
    }

    private void SetupDisplay()
    {
        var tr = GetNode<TextureRect>(OutputTextureRectPath);

        // Create a Godot Texture2D wrapper around the RID.
        // In Godot 4, you can use Texture2DRD.
        var tex = new Texture2DRD();
        tex.TextureRid = _outputTexRid;

        _displayTexture = tex;
        tr.Texture = _displayTexture;
        tr.ExpandMode = TextureRect.ExpandModeEnum.IgnoreSize;
        tr.StretchMode = TextureRect.StretchModeEnum.Scale;
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