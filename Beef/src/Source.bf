using System;
using System.IO;
using System.Collections;
using System.Diagnostics;
using System.Globalization;

namespace Monkey;

struct SourceIndex : this(int line, int col, Source src)
{
	public static Self operator+ (Self lhs, Self rhs)
	{
		Runtime.Assert(lhs.src === rhs.src);
		return .(lhs.line + rhs.line, lhs.col + rhs.col, lhs.src);
	}

	public static Self operator- (Self lhs, Self rhs)
	{
		Runtime.Assert(lhs.src === rhs.src);
		return .(lhs.line - rhs.line, lhs.col - rhs.col, lhs.src);
	}

	public static bool operator>= (Self lhs, Self rhs)
	{
		if (lhs.src !== rhs.src) return false;
		if (lhs.line < rhs.line) return false;
		if (lhs.line == rhs.line && lhs.col < rhs.col) return false;
		return true;
	}
}

interface IErrorOutput
{
	//NOTE: Ranges are inclusive

	public Queue<(SourceIndex idx, String name)> StackTrace { get; set; }

	public void Fail(Range<SourceIndex> idx, StringView msg, params Object[] formatArgs);
	public void Fail(SourceIndex idx, StringView msg, params Object[] formatArgs);
	public void Fail(StringView msg, params Object[] formatArgs);

	public void Warn(Range<SourceIndex> idx, StringView msg, params Object[] formatArgs);
	public void Warn(SourceIndex idx, StringView msg, params Object[] formatArgs);
	public void Warn(StringView msg, params Object[] formatArgs);
}

class Source : this(StreamReader stream, StringView origin, IErrorOutput output, BumpAllocator alloc)
{
	public SourceIndex index = .(0, 0, this);
	protected Queue<AstNode> cycle = new .() ~ delete _;

	public void Cycle(AstNode node) => cycle.Add(node);

	protected mixin ReturnCycling()
	{
		if (!cycle.IsEmpty)
			return cycle.PopFront();
	}

	protected void MoveNext()
	{
		if (stream.Read().Value == '\n')
		{
			index.line++;
			index.col = 0;
		}
		else index.col++;
	}

	protected void ConsumeWhitespace()
	{
		while (stream.Peek() case .Ok(let val) && (val.IsWhiteSpace))
			MoveNext();
	}

	protected Result<void> NextWord(String outString)
	{
		if (stream.Peek() case .Ok(let val) && val.IsLetter)
		{
			outString.Append(val);
			MoveNext();
		}	
		else
			return .Err;
		while (stream.Peek() case .Ok(let val) && (val.IsLetterOrDigit || val == '_'))
		{
			outString.Append(val);
			MoveNext();
		}
		return .Ok;
	}

	public Result<AstNode> NextTokenOrIdentifier()
	{
		ReturnCycling!();
		ConsumeWhitespace();
		TokenNode node = new:alloc .(default) { position = .() };
		node.position.Start = index;

		do
		{
			if (stream.EndOfStream)
			{
				node.token = .EOF;
				node.position.End = index;
				break;
			}

			switch (stream.Peek().Value)
			{
			case '+': node.token = .Plus;
			case '-': node.token = .Dash;
			case '*': node.token = .Asterisk;
			case '>': node.token = .GreaterThan;
			case '<': node.token = .LessThan;
			case '(': node.token = .LParen;
			case ')': node.token = .RParen;
			case '{': node.token = .LSquirly;
			case '}': node.token = .RSquirly;
			case '[': node.token = .LBracket;
			case ']': node.token = .RBracket;
			case ';': node.token = .Semicolon;
			case ',': node.token = .Comma;
			case ':': node.token = .Colon;
			case '"', '\'':
				output.Fail(index, "Unexpected string literal");
				return .Err;
			when _.IsDigit:
				output.Fail(index, "Unexpected number");
				return .Err;
			}
			if (node.token != default)
			{
				MoveNext();
				node.position.End = index;
				break;
			}

			String buffer = scope .(8);
			int i = 0;
			while (stream.Peek() case .Ok(let val) && (!val.IsLetterOrDigit && !val.IsWhiteSpace && val != '_') && i++ < 2)
			{
				buffer.Append(val);
				MoveNext();
			}

			if (buffer.IsEmpty)
			{
				NextWord(buffer);
				node.position.End = index;
				switch (buffer)
				{
				case "let": node.token = .Let;
				case "fn": node.token = .Function;
				case "if": node.token = .If;
				case "else": node.token = .Else;
				case "return": node.token = .Return;
				case "true": return new:alloc BoolLiteral(true) { position = node.position };
				case "false": return new:alloc BoolLiteral(true) { position = node.position };
				}

				if (node.token == .Illegal)
					return new:alloc IdentifierNode(new:alloc String(buffer)) { position = node.position };

				break;
			}

			node.position.End = index;
			switch (buffer)
			{
			case "==": node.token = .Equal;
			case "!=": node.token = .NotEqual;
			case "&&": node.token = .ConditionalAnd;
			case "||": node.token = .ConditionalOr;
			case "!": node.token = .Bang;
			case "=": node.token = .Assign;
			case "/": node.token = .ForwardSlash;
			case "//":
				while (stream.Peek() case .Ok(let val) && val != '\n') MoveNext();
				return NextTokenOrIdentifier();
			case "/*":
				loop: while (true) peek: switch (stream.Peek())
				{
				case .Ok('*'):
					MoveNext();
					switch (stream.Peek())
					{
					case .Err:
						fallthrough peek;
					case .Ok('/'):
						MoveNext();
						break loop;
					case .Ok:
					}
				case .Err:
					output.Fail(index, "Multiline comment was not closed");
				case .Ok:
					MoveNext();
				}
				return NextTokenOrIdentifier();
			}

			if (node.token == .Illegal)
			{
				output.Fail(node.position, $"Invalid operator '{buffer}'");
				return .Err;
			}
		}

		return node;
	}

	public Result<AstNode> ParseNext()
	{
		ReturnCycling!();
		ConsumeWhitespace();
		switch (stream.Peek())
		{
		case .Err:
			return .Ok(new:alloc TokenNode(.EOF) { position = .(index, index) });
		case .Ok('"'), .Ok('\''):
			let startIndex = index;
			MoveNext();
			String buffer = scope .(32);
			bool escaped = false;
			while (stream.Peek() case .Ok(let val) && (val != _.Value || escaped))
			{
				escaped = val == '\\';
				buffer.Append(val);
				MoveNext();
			}
			if (stream.EndOfStream)
			{
				output.Fail(index, "String literal was not closed");
				return .Err;
			}
			MoveNext();
			String unescaped = new:alloc .(buffer.Length);
			if (buffer.Unescape(unescaped) case .Err)
			{
				output.Fail(Range<SourceIndex>(startIndex, index), "Failed to unescape string");
				return .Err;
			}
			return .Ok(new:alloc StringLiteral(unescaped) { position = .(startIndex, index) });
		case .Ok(let c):
			if (!c.IsDigit) fallthrough;
			String buffer = scope .(8);
			let startIndex = index;
			while (stream.Peek() case .Ok(let val) && "0123456789abcdefABCDEFx_".Contains(val))
			{
				if (val != '_')
					buffer.Append(val);
				MoveNext();
			}
			switch (int32.Parse(buffer, .AllowHexSpecifier))
			{
			case .Ok(let val):
				return .Ok(new:alloc IntLiteral(val) { position = .(startIndex, index) });
			case .Err(let err):
				output.Fail(Range<SourceIndex>(startIndex, index), $"Failed to parse number: {err}");
				return .Err;
			}
		default:
			return NextTokenOrIdentifier();
		}
	}

	public Result<IdentifierNode> ExpectIdentifier()
	{
		if (!cycle.IsEmpty)
		{
			let node = cycle.PopFront();
			let identifier = node as IdentifierNode;
			if (identifier == null)
			{
				output.Fail(node.position, "Expected identifier");
				return .Err;
			}
			return identifier;
		}
		ConsumeWhitespace();
		String buffer = new:alloc .(8);
		let startIndex = index;
		if (NextWord(buffer) case .Err)
		{
			output.Fail(startIndex, "Expected identifier");
			return .Err;
		}
		return .Ok(new:alloc .(buffer) { position = .(startIndex, index) });
	}

	public Result<TokenNode> ExpectToken(Token expected)
	{
		let next = Try!(NextTokenOrIdentifier());
		let token = next as TokenNode;
		if (token == null || token.token != expected)
		{
			output.Fail(next.position, $"Expected {expected}");
			return .Err;
		}
		return token;
	}

	public Result<TokenNode> NextToken()
	{
		let next = Try!(NextTokenOrIdentifier());
		let token = next as TokenNode;
		if (token == null)
		{
			output.Fail(next.position, "Expected token");
			return .Err;
		}
		return token;
	}

	public Result<bool> NextTokenCase(Token t, out TokenNode outNode)
	{
		outNode = null;
		let next = Try!(ParseNext());
		outNode = next as TokenNode;
		if (outNode == null || !(outNode.token case t))
		{
			Cycle(next);
			return false;
		}
		return true;
	}
}
