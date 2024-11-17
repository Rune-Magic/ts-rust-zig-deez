using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Monkey;

class ConsoleErrors : IErrorOutput
{
	public Queue<(SourceIndex idx, String name)> StackTrace { get; set; } = null;

	private void WriteLineIndex(Range<SourceIndex> idx)
	{
		if (idx.Start.src == null)
		{
			Console.WriteLine();
			return;
		}
		Console.WriteLine($" at line {idx.Start.line+1}:{idx.Start.col+1} in {idx.Start.src.origin}");
	}

	public void Fail(Range<SourceIndex> idx, StringView msg, params Object[] formatArgs)
	{
		let prev = Console.ForegroundColor;
		Console.ForegroundColor = .Red;
		Console.Write("ERROR: ");
		Console.ForegroundColor = .Gray;
		Console.Write(msg, params formatArgs);
		WriteLineIndex(idx);
		if (StackTrace != null)
		{
			Console.ForegroundColor = .DarkGray;
			for (let entry in StackTrace)
			{
				Console.Write("> in ");
				Console.Write(entry.name);
				WriteLineIndex(.(entry.idx, entry.idx));
			}
		}
		Console.ForegroundColor = prev;
		Debug.SafeBreak();
	}

	[Inline]
	public void Fail(SourceIndex idx, StringView msg, params Object[] formatArgs)
	{
		Fail(Range<SourceIndex>(idx, idx), msg, params formatArgs);
	}

	[Inline]
	public void Fail(StringView msg, params Object[] formatArgs)
	{
		Fail(default(SourceIndex), msg, params formatArgs);
	}

	public void Warn(Range<SourceIndex> idx, StringView msg, params Object[] formatArgs)
	{
		let prev = Console.ForegroundColor;
		Console.ForegroundColor = .Yellow;
		Console.Write("WARNING: ");
		Console.ForegroundColor = .Gray;
		Console.Write(msg, params formatArgs);
		WriteLineIndex(idx);
		Console.ForegroundColor = prev;
	}

	[Inline]
	public void Warn(SourceIndex idx, StringView msg, params Object[] formatArgs)
	{
		Fail(Range<SourceIndex>(idx, idx), msg, params formatArgs);
	}

	[Inline]
	public void Warn(StringView msg, params Object[] formatArgs)
	{
		Warn(default(SourceIndex), msg, params formatArgs);
	}
}

class Program
{
	public static int Main(String[] args)
	{
		ConsoleErrors output = scope .();
		output.Fail("test");
		output.Warn("test");
		Console.Read();
		return 0;
	}
}