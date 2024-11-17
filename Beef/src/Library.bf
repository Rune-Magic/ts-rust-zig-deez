using System;
using System.Collections;
using System.Diagnostics;

namespace Monkey;

class Library
{
	public typealias Output = Result<Interpreter.ReturnAction>;

	protected List<(StringView name, StringView[] parameters, delegate Output(Interpreter interp) invoke)> functions = new .() ~
		{
			for (let item in _)
			{
				delete item.parameters;
				delete item.invoke;
			}
			delete _;
		}

	private static readonly Dictionary<StringView, MonkeyValue> sEmptyCaputures = new .() ~ delete _;
	private static readonly bool* sFalseRef = new .() ~ delete _;
	public Result<void> Init(Interpreter interp)
	{
		let alloc = interp.[Friend]alloc;
		for (let func in functions)
		{
			List<IdentifierNode> parameters = new:alloc .(func.parameters.Count);
			for (let par in func.parameters)
				parameters.Add(new:alloc .(par));
			Try!(interp.DeclVar(func.name, .Function(new:alloc .(null, parameters, new:alloc ExternalInvokation(this, @func.Index), .()), sEmptyCaputures, sFalseRef), default));
		}
		return .Ok;
	}

	public void Add<TArgs>(StringView name, StringView[] parameters, function Output(Interpreter, TArgs) func)
	{
		[Comptime]
		void Emit()
		{
			Type args = typeof(TArgs);
			String str = scope .("functions.Add((name, parameters, (.)new (interp) => func(interp, ");
			if (args.IsTuple)
			{
				str.Append('(');
				for (let i < args.FieldCount)
					str.AppendF($"interp.GetVarValue(parameters[{i}], default), ");
				str.RemoveFromEnd(2);
				str.Append(')');
			}
			else if (args.IsSubtypeOf(typeof(void)) || args.IsGenericParam)
				str.Append("default");
			else
				str.Append("interp.GetVarValue(parameters[0], default)");

			str.Append(")));");
			Compiler.MixinRoot(str);
		}
		Emit();
	}

	public Output Call(int id, Interpreter interp) => functions[id].invoke(interp);
}

public class CoreLibrary : Library
{
	protected static Result<void> Assert(bool condition, Interpreter intr, StringView errorMsg, params Object[] formatArgs)
	{
		if (!condition)
		{
			intr.output.Fail(errorMsg, params formatArgs);
			return .Err;
		}
		return .Ok;
	}

	public static Library.Output puts(Interpreter intr, MonkeyValue value)
	{
		Console.WriteLine(value.ToValueString(..scope .()));
		return default;
	}

	public static Library.Output map(Interpreter intr, (MonkeyValue target, MonkeyValue func) args)
	{
		Try!(Assert(args.func case .Function(let expr, ?, ?), intr, $"second argument of map must be a function, got {args.func}"));
		switch (args.target)
		{
		case .Array(let arr):
			for (let item in arr.Value)
				Try!(intr.Invoke(args.func, "<map_function>", null, .CreateCopy(item)));
		case .Dict(let dict):
			for (let kv in dict.Value)
				Try!(intr.Invoke(args.func, "<map_function>", null, .CreateCopy(kv.key), .CreateCopy(kv.value)));
		default:
			intr.output.Fail($"Cannot map over {args.target}");
		}
		return default;
	}

	public static Library.Output assert(Interpreter intr, MonkeyValue condition)
	{
		Try!(Assert(condition case .Bool(let bool), intr, $"Cannot assert {condition}"));
		Try!(Assert(bool, intr, "Assert failed"));
		return default;
	}

	public this()
	{
		Add<MonkeyValue>("puts", new .("value"), => puts);
		Add<(MonkeyValue target, MonkeyValue func)>("map", new .("target", "func"), => map);
		Add<MonkeyValue>("assert", new .("condition"), => assert);
	}
}
