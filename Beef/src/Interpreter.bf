using System;
using System.Collections;
using System.Diagnostics;

namespace Monkey;

public enum MonkeyValue : IHashable, IRefCounted
{
	case Int(int), Bool(bool);
	case String(RefCounted<String>);
	case Array(RefCounted<MonkeyValue[]>);
	case Function(FunctionExpression, Dictionary<StringView, MonkeyValue> captures, bool* capturesLocked);
	case Dict(RefCounted<Dictionary<MonkeyValue, MonkeyValue>>);

	public static operator Self(int val) => .Int(val);
	public static operator Self(bool val) => .Bool(val);
	public static operator Self(String val) => .String(.Attach(val));
	public static operator Self(MonkeyValue[] val) => .Array(.Attach(val));
	public static operator Self(Dictionary<MonkeyValue, MonkeyValue> val) => .Dict(.Attach(val));

	public static Self CreateCopy(Self self)
	{
		switch (self)
		{
		case .Int, .Bool, .Function:
			return self;
		case .String(let str):
			return new String(str);
		case .Array(let arr):
			Self[] newArr = new .[arr->Count];
			for (let item in arr.Value)
				newArr[@item] = CreateCopy(item);
			return newArr;
		case .Dict(let dict):
			Dictionary<MonkeyValue, MonkeyValue> newDict = new .((.)dict->Count);
			for (let kv in dict.Value)
				newDict.Add(CreateCopy(kv.key), CreateCopy(kv.value));
			return newDict;
		}
	}

	public override void ToString(String strBuffer)
	{
		switch (this)
		{
		case Int: strBuffer.Append("int");
		case String: strBuffer.Append("string");
		case Bool: strBuffer.Append("bool");
		case Array: strBuffer.Append("array");
		case Function: strBuffer.Append("function");
		case Dict: strBuffer.Append("dict");
		}
	}

	public int GetHashCode()
	{
		switch (this)
		{
		case .Int(IHashable hashable), .Bool(out hashable):
			return hashable.GetHashCode();
		case .String(let str):
			return str->GetHashCode();
		case .Function(let obj, ?, ?):
			return (int)Internal.UnsafeCastToPtr(obj); // good enough
		case .Array(let arr):
			int hash = arr->Count;
			for (let item in arr.Value)
				hash = HashCode.Mix(hash, item.GetHashCode());
			return hash;
		case .Dict(let dict):
			int hash = dict->Count;
			for (let kv in dict.Value)
				hash = HashCode.Mix(hash, HashCode.Mix(kv.key.GetHashCode(), kv.value.GetHashCode()));
			return hash;
		}
	}

	[Commutable]
	public static bool operator== (Self lhs, Self rhs)
	{
		if (lhs === rhs) return true;
		if (lhs case .String(let p0) && rhs case .String(let p1))
		{
			return StringView(p0) == StringView(p1);
		}
		if (lhs case .Array(let p0) && rhs case .Array(let p1))
		{
			if (p0->Count != p1->Count) return false;
			for (let item in p0.Value)
				if (item != p1.Value[@item])
					return false;
			return true;
		}
		if (lhs case .Dict(let p0) && rhs case .Dict(let p1))
		{
			if (p0->Count != p1->Count) return false;
			for (let kv in p0.Value)
				if (!p1->TryGet(kv.key, ?, let value) || value != kv.value)
					return false;
			return true;
		}
		return false;
	}

	public void ToValueString(String strBuffer)
	{
		void Subvalue(Self value, String strBuffer)
		{
			if (value case .String(let str))
				str->Quote(strBuffer);
			else
				value.ToValueString(strBuffer);
		}

		switch (this)
		{
		case .Int(let val): val.ToString(strBuffer);
		case .String(let val): strBuffer.Append(val);
		case .Bool(let val): val.ToString(strBuffer);
		case .Function(let val, ?, ?):
			strBuffer.Append("function (");
			for (let param in val.parameters)
				strBuffer..Append(param.identifier)..Append(", ");
			if (!val.parameters.IsEmpty)
				strBuffer.RemoveFromEnd(2);
			strBuffer.Append(')');
		case .Array(let val):
			strBuffer.Append('[');
			for (let param in val.Value)
			{
				Subvalue(param, strBuffer);
				strBuffer.Append(", ");
			}
			if (!val->IsEmpty)
				strBuffer.RemoveFromEnd(2);
			strBuffer.Append(']');
		case .Dict(let dict):
			strBuffer.Append('{');
			for (let kv in dict.Value)
			{
				Subvalue(kv.key, strBuffer);
				strBuffer.Append(": ");
				Subvalue(kv.value, strBuffer);
				strBuffer.Append(", ");
			}
			if (!dict->IsEmpty)
				strBuffer.RemoveFromEnd(2);
			strBuffer.Append('}');
		}
	}

	public void AddRef()
	{
		switch (this)
		{
		case .String(let val):
			val.AddRef();
		case .Array(let val):
			for (let item in val.Value)
				item.AddRef();
			val.AddRef();
		case .Dict(let val):
			for (let kv in val.Value)
			{
				kv.key.AddRef();
				kv.value.AddRef();
			}
			val.AddRef();
		case .Function(?, let captures, ?):
			for (let capture in captures)
				capture.value.AddRef();
		case .Int, .Bool:
		}
	}

	public void Release()
	{
		switch (this)
		{
		case .String(let val):
			val.Release();
		case .Array(let val):
			for (let item in val.Value)
				item.Release();
			val.Release();
		case .Dict(let val):
			for (let kv in val.Value)
			{
				kv.key.Release();
				kv.value.Release();
			}
			val.Release();
		case .Function(?, let captures, ?):
			for (let capture in captures)
				capture.value.Release();
		case .Int, .Bool:
		}
	}
}

class Interpreter
{
	protected enum ScopeType
	{
		case Block, Function(MonkeyValue definition, StringView callee);
	}

	protected class Scope : this(ScopeType type, List<MonkeyValue> funcs);
	protected struct Variable : this(Scope scop, StringView identifier), IHashable
	{
		public int GetHashCode()
		{
			return identifier.GetHashCode();
		}

		public static bool operator== (Self lhs, Self rhs)
		{
			if (lhs.scop !== rhs.scop) return false;
			if (lhs.identifier != rhs.identifier) return false;
			return true;
		}
	}

	//protected Parser parser;
	public IErrorOutput output;
	protected BumpAllocator alloc;
	protected Queue<Scope> scopes = new .(4) ~ delete _;
	protected Dictionary<Variable, MonkeyValue> variables = new .(32) ~ delete _;
	protected Queue<(SourceIndex idx, String name)> stackTrace = new .(4) ~ delete _;
	protected Queue<Queue<MonkeyValue>> scopedValues = new .(4) ~ delete _;

	public this(Parser parser)
	{
		alloc = parser.Source.alloc;
		output = parser.Source.output;
		output.StackTrace = stackTrace;
		stackTrace.AddFront((parser.Source.index, new:alloc .(parser.Source.origin)));
	}

	public ~this()
	{
		Debug.Assert(scopes.IsEmpty);
	}

	public Result<void> ScopeIn(ScopeType type = .Block, SourceIndex idx = default)
	{
		scopes.AddFront(new:alloc .(type, new:alloc .()));
		scopedValues.Add(new .(5));
		if (type case .Function(let definition, let callee))
		{
			String name = new .(32);
			definition.ToValueString(name);
			name.Insert("function ".[ConstEval]Length, callee);
			stackTrace.AddFront((idx, name));
		}
		return .Ok;
	}

	public Result<void> ScopeOut()
	{
		let scop = scopes.Front;
		for (let f in scop.funcs)
		{
			Runtime.Assert(f case .Function(let func, let captures, let capturesLocked));
			*capturesLocked = true;
			for (let capture in func.captures)
				captures.Add(capture, .CreateCopy(Try!(GetVarValue(capture, .())))..AddRef());
		}
		let values = scopedValues.PopBack();
		for (let val in values)
			val.Release();
		delete values;
		for (let (key, value) in variables)
			if (key.scop === scop)
				value.Release();
		if (scop.type case .Function)
			delete stackTrace.PopFront().name;
		scopes.PopFront();
		return .Ok;
	}

	[NoDiscard]
	public Result<MonkeyValue> GetVarValue(StringView identifier, Range<SourceIndex> idx)
	{
		loop: for (let s in scopes)
		{
			if (!variables.TryGet(.(s, identifier), ?, let value))
				switch (s.type)
				{
				case .Function(let definition, ?):
					Runtime.Assert(definition case .Function(?, let captures, let capturesLocked));
					if (!*capturesLocked) continue;
					for (let capture in captures)
					{
						if (capture.key == identifier)
							return capture.value;
					}
					break loop;
				case .Block:
					continue;
				}
			return value;
		}

		output.Fail(idx, $"Identifier '{identifier}' not found");
		return .Err;
	}

	[NoDiscard]
	protected Result<Variable> GetVariable(StringView identifier, Range<SourceIndex> idx)
	{
		loop: for (let s in scopes)
		{
			Variable variable = .(s, identifier);
			if (!variables.TryGet(variable, ?, let value))
				switch (s.type)
				{
				case .Function(let definition, ?):
					Runtime.Assert(definition case .Function(let func, let captures, let capturesLocked));
					if (*capturesLocked) break loop; // locked captures can't be changed
					continue;
				case .Block:
					continue;
				}
			return variable;
		}

		output.Fail(idx, $"Variable '{identifier}' is immutable or doesn't exist");
		return .Err;
	}

	public Result<void> DeclVar(StringView identifier, MonkeyValue init, Range<SourceIndex> idx)
	{
		loop: for (let s in scopes)
		{
			Variable variable = .(s, identifier);
			if (!variables.TryGet(variable, ?, ?))
				switch (s.type)
				{
				case .Function:
					break loop;
				case .Block:
					continue;
				}

			output.Fail(idx, $"Variable '{identifier}' already exists");
			return .Err;
		}

		Variable variable = .(scopes.Front, identifier);
		variables.Add(variable, init);
		return .Ok;
	}

	[NoDiscard]
	public Result<ReturnAction> Invoke(MonkeyValue func, StringView callee, InvokationExpression invokation = null, params Span<MonkeyValue> args)
	{
		Try!(Assert(func case .Function(let funcExpr, ?, ?), invokation?.func.position ?? .(), $"Unable to invoke {func}"));
		Try!(Assert(funcExpr.parameters.Length == args.Length, invokation?.rParen.position ?? .(), $"Expected {funcExpr.parameters.Length} arguments, got {args.Length}"));
		Try!(ScopeIn(.Function(func, callee), invokation == null ? default : invokation.position.Start));
		for (let i < args.Length)
			DeclVar(funcExpr.parameters[i].identifier, .CreateCopy(args[i]), default);
		let result = Try!(Execute(funcExpr.body));
		Try!(ScopeOut());
		return result;
	}

	Result<void> Assert(bool condition, Range<SourceIndex> index, StringView error, params Object[] formatArgs)
	{
		if (!condition)
		{
			output.Fail(index, error, params formatArgs);
			return .Err;
		}
		return .Ok;
	}

	public enum ReturnAction
	{
		case DidntReturn, ReturnedVoid, ReturnedValue(MonkeyValue);
	}

	public Result<ReturnAction> Execute(StatementNode node)
	{
		if (let block = node as BlockNode)
		{
			Try!(ScopeIn());
			for (let statement in block.statements)
				switch (Try!(Execute(statement)))
				{
				case .DidntReturn:
				default:
					Try!(ScopeOut());
					return _;
				}
			Try!(ScopeOut());
			return default;
		}

		if (let expr = node as ExpressionStatement)
		{
			Try!(Assert(expr.expr is InvokationExpression, expr.expr.position, "This expression cannot be used as a statement"));
			Try!(Evaluate(expr.expr, allowVoid: true));
			return default;
		}

		if (let decl = node as LetStatement)
		{
			Try!(DeclVar(decl.varName.identifier, Try!(Evaluate(decl.value))..AddRef(), decl.varName.position));
			return default;
		}

		if (let reassign = node as ReassignStatement)
		{
			Runtime.Assert(variables.TryGetRef(Try!(GetVariable(reassign.varName.identifier, reassign.varName.position)), ?, let value));
			let old = *value;
			*value = Try!(Evaluate(reassign.newValue))..AddRef();
			old.Release();
			return default;
		}

		if (let returns = node as ReturnStatement)
		{
			if (returns.value == null)
				return .Ok(.ReturnedVoid);
			return .Ok(.ReturnedValue(Try!(Evaluate(returns.value))..AddRef()));
		}

		if (let conditional = node as IfStatement)
		{
			let value = Try!(Evaluate(conditional.condition));
			Try!(Assert(value case .Bool(let bool), conditional.condition.position, $"Expected bool, got {value}"));
			Try!(ScopeIn());
			ReturnAction result = ?;
			if (bool)
				result = Try!(Execute(conditional.ifBlock));
			else if (conditional.elseToken != null)
				result = Try!(Execute(conditional.elseBlock));
			Try!(ScopeOut());
			return result;
		}

		if (let external = node as ExternalInvokation)
			return Try!(external.lib.Call(external.id, this));

		Runtime.FatalError();
	}

	public Result<MonkeyValue> Evaluate(ExpressionNode expr, bool allowVoid = false)
	{
		defer
		{
			if (@return case .Ok(let ok))
				scopedValues.Back.Add(ok);
		}

		if (let literal = expr as IntLiteral)
			return .Ok(literal.value);

		if (let literal = expr as StringLiteral)
			return .Ok(new String(literal.value));

		if (let literal = expr as BoolLiteral)
			return .Ok(literal.value);

		if (let func = expr as FunctionExpression)
		{
			MonkeyValue f = .Function(func, new:alloc .(), new:alloc .());
			scopes.Front.funcs.Add(f);
			return .Ok(f);
		}

		if (let variable = expr as VariableExpression)
			return .Ok(.CreateCopy(Try!(GetVarValue(variable.varName.identifier, variable.position))));

		if (let encaups = expr as EncaupsulatedExpression)
			return Evaluate(encaups.expr);

		if (let negation = expr as NegationExpression)
		{
			let value = Try!(Evaluate(negation.input));
			Try!(Assert(value case .Bool(let bool), negation.input.position, $"Expected bool, got {value}"));
			return .Ok(.Bool(!bool));
		}

		if (let invokation = expr as InvokationExpression)
		{
			let varExpr = invokation.func as VariableExpression;
			StringView callee = varExpr?.varName.identifier ?? "<anonymous>";
			let value = Try!(Evaluate(invokation.func));
			MonkeyValue[] args = scope .[invokation.args.Length];
			for (let i < args.Count)
				args[i] = Try!(Evaluate(invokation.args[i]));
			switch (Try!(Invoke(value, callee, invokation, params args)))
			{
			case .ReturnedValue(let val):
				return .Ok(.CreateCopy(val));
			default:
				if (allowVoid)
					return .Ok(default);
				output.Fail("Function didn't return a value");
				return .Err;
			}
		}	

		if (let index = expr as IndexExpression)
		{
			let value = Try!(Evaluate(index.expr));
			let idx = Try!(Evaluate(index.index));
			switch (value)
			{
			case .Array(let arr):
				Try!(Assert(idx case .Int(let int), index.index.position, $"Expected int, got {idx}"));
				Try!(Assert(int >= 0 && int < arr->Count, index.index.position, "Index out of range"));
				return .Ok(.CreateCopy(arr.Value[int]));
			case .Dict(let dict):
				Try!(Assert(dict->TryGet(idx, ?, let output), index.index.position, "Key not found"));
				return .Ok(.CreateCopy(output));
			default:
				output.Fail(index.lBracket.position, $"Cannot use index operator on {value}");
				return .Err;
			}
		}

		if (let op = expr as OperationExpression)
		{
			let lhs = Try!(Evaluate(op.lhs));
			let rhs = Try!(Evaluate(op.rhs));
			switch (op.operation.token)
			{
			case .Plus:
				switch (lhs)
				{
				case .Int(let val1):
					Try!(Assert(rhs case .Int(let val2), expr.position, $"Cannot add int and {rhs}"));
					return .Ok(val1 + val2);
				case .String(let val1):
					String str = new .(val1);
					rhs.ToValueString(str);
					return .Ok(str);
				case .Array(let val1):
					Try!(Assert(rhs case .Array(let val2), expr.position, $"Cannot add array and {rhs}"));
					MonkeyValue[] output = new .[val1->Count + val2->Count];
					int i = 0;
					for (let item in val1.Value)
						output[i++] = .CreateCopy(item);
					for (let item in val2.Value)
						output[i++] = .CreateCopy(item);
					return .Ok(output);
				case .Dict(let val1):
					Try!(Assert(rhs case .Dict(let val2), expr.position, $"Cannot add dict and {rhs}"));
					Dictionary<MonkeyValue, MonkeyValue> output = new .((.)val1->Count + (.)val2->Count);
					for (let kv in val1.Value)
						output.Add(.CreateCopy(kv.key), .CreateCopy(kv.value));
					for (let kv in val2.Value)
						output.Add(.CreateCopy(kv.key), .CreateCopy(kv.value));
					return .Ok(output);
				default:
					output.Fail(expr.position, $"Cannot add {lhs} and {rhs}");
					return .Err;
				}
			case .Dash:
				if (lhs case .Int(let val1) && rhs case .Int(let val2))
					return .Ok(val1 - val2);
				output.Fail(expr.position, $"Cannot subtract {lhs} from {rhs}");
				return .Err;
			case .Asterisk:
				if (lhs case .Int(let val1) && rhs case .Int(let val2))
					return .Ok(val1 * val2);
				output.Fail(expr.position, $"Cannot multiply {lhs} and {rhs}");
				return .Err;
			case .ForwardSlash:
				if (lhs case .Int(let val1) && rhs case .Int(let val2))
					return .Ok(val1 / val2);
				output.Fail(expr.position, $"Cannot divide {lhs} and {rhs}");
				return .Err;
			case .Equal:
				return .Ok(lhs == rhs);
			case .NotEqual:
				return .Ok(lhs != rhs);
			case .GreaterThan:
				if (lhs case .Int(let val1) && rhs case .Int(let val2))
					return .Ok(val1 > val2);
				output.Fail(expr.position, $"Cannot compare {lhs} and {rhs}");
				return .Err;
			case .LessThan:
				if (lhs case .Int(let val1) && rhs case .Int(let val2))
					return .Ok(val1 < val2);
				output.Fail(expr.position, $"Cannot compare {lhs} and {rhs}");
				return .Err;
			case .ConditionalAnd:
				if (lhs case .Bool(let val1) && rhs case .Bool(let val2))
					return .Ok(val1 && val2);
				output.Fail(expr.position, $"Cannot '&&' {lhs} and {rhs}");
				return .Err;
			case .ConditionalOr:
				if (lhs case .Bool(let val1) && rhs case .Bool(let val2))
					return .Ok(val1 || val2);
				output.Fail(expr.position, $"Cannot '||' {lhs} and {rhs}");
				return .Err;
			default:
				Runtime.FatalError();
			}
		}

		if (let array = expr as ArrayExpression)
		{
			MonkeyValue[] values = new .[array.values.Length];
			for (let value in array.values)
				values[@value.Index] = Try!(Evaluate(value))..AddRef();
			return .Ok(values);
		}

		if (let dict = expr as DictExpression)
		{
			Dictionary<MonkeyValue, MonkeyValue> output = new .((.)dict.keys.Length);
			for (let i < dict.keys.Length)
				Try!(Assert(output.TryAdd(Try!(Evaluate(dict.keys[i]))..AddRef(), Try!(Evaluate(dict.values[i]))..AddRef()), dict.keys[i].position, "Duplicate key"));
			return .Ok(output);
		}

		Runtime.FatalError();
	}
}