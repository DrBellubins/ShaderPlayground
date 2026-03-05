using Godot;
using System;
using System.Collections.Generic;

public static class Debug
{
	public static bool IsDebugVisible = true;
	public static List<string> DebugTextList = new List<string>();

	public static void Write(string text)
	{
		if (IsDebugVisible)
			DebugTextList.Add(text);
    }
}

public partial class DebugTextDraw : Label
{
	public override void _Process(double delta)
	{
        Text = "";

        for (int i = 0; i < Debug.DebugTextList.Count; i++)
		{
			Text += $"{Debug.DebugTextList[i]}\n";
        }
		
        Debug.DebugTextList.Clear();
    }
}