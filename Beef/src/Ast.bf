using System;
using System.Collections;

namespace Monkey;

abstract class AstNode
{
	public Range<SourceIndex> position;
}

enum Token
{
	case Illegal,

	Let,
	EOF,
	Assign,
	Plus,
	Comma,
	Colon,
	Semicolon,
	LParen,
	RParen,
	LSquirly,
	RSquirly,
	LBracket,
	RBracket,

	Bang,
	Dash,
	ForwardSlash,
	Asterisk,
	LessThan,
	GreaterThan,
	ConditionalAnd,
	ConditionalOr,

	Equal,
	NotEqual,

	If,
	Else,
	Return,
	Function;

	public override void ToString(String strBuffer)
	{
		switch (this)
		{
		case .Illegal: strBuffer.Append("<error>");
		case .Let: strBuffer.Append("'let'");
		case .EOF: strBuffer.Append("end of file");
		case .Assign: strBuffer.Append("'='");
		case .Plus: strBuffer.Append("'+'");
		case .Comma: strBuffer.Append("','");
		case .Colon: strBuffer.Append("':'");
		case .Semicolon: strBuffer.Append("semicolon");
		case .LParen: strBuffer.Append("'('");
		case .RParen: strBuffer.Append("')'");
		case .LSquirly: strBuffer.Append("'{'");
		case .RSquirly: strBuffer.Append("'}'");
		case .LBracket: strBuffer.Append("'['");
		case .RBracket: strBuffer.Append("']'");
		case .Bang: strBuffer.Append("'!'");
		case .Dash: strBuffer.Append("'-'");
		case .ForwardSlash: strBuffer.Append("'/'");
		case .Asterisk: strBuffer.Append("'*'");
		case .LessThan: strBuffer.Append("'<'");
		case .GreaterThan: strBuffer.Append("'>'");
		case .ConditionalAnd: strBuffer.Append("'&&'");
		case .ConditionalOr: strBuffer.Append("'||'");
		case .Equal: strBuffer.Append("'=='");
		case .NotEqual: strBuffer.Append("'!='");
		case .If: strBuffer.Append("'if'");
		case .Else: strBuffer.Append("'else'");
		case .Return: strBuffer.Append("'return'");
		case .Function: strBuffer.Append("'fn'");
		}
	}
}

class TokenNode : AstNode, this(Token token);
class IdentifierNode : AstNode, this(StringView identifier);

//////////////////////////////////////////////////////////////////////////////////

abstract class ExpressionNode : AstNode { }

class StringLiteral : ExpressionNode, this(StringView value);
class IntLiteral : ExpressionNode, this(int32 value);
class BoolLiteral : ExpressionNode, this(bool value);

class NegationExpression : ExpressionNode, this(TokenNode bang, ExpressionNode input);
class OperationExpression : ExpressionNode, this(ExpressionNode lhs, TokenNode operation, ExpressionNode rhs);
class InvokationExpression : ExpressionNode, this(ExpressionNode func, TokenNode lParen, Span<ExpressionNode> args, TokenNode rParen);
class VariableExpression : ExpressionNode, this(IdentifierNode varName);
class IndexExpression : ExpressionNode, this(ExpressionNode expr, TokenNode lBracket, ExpressionNode index, TokenNode rBracket);

class ArrayExpression : ExpressionNode, this(TokenNode lBracket, Span<ExpressionNode> values, TokenNode rBracket);
class DictExpression : ExpressionNode, this(TokenNode lBracket, Span<ExpressionNode> keys, Span<ExpressionNode> values, TokenNode rBracket);
class EncaupsulatedExpression : ExpressionNode, this(TokenNode lParen, ExpressionNode expr, TokenNode rParen);
class FunctionExpression : ExpressionNode, this(TokenNode fnToken, Span<IdentifierNode> parameters, StatementNode body, Span<StringView> captures);

//////////////////////////////////////////////////////////////////////////////////

abstract class StatementNode : AstNode { public TokenNode semicolon; }

class LetStatement : StatementNode, this(TokenNode letKeyword, IdentifierNode varName, TokenNode equals, ExpressionNode value);
class ReassignStatement : StatementNode, this(IdentifierNode varName, TokenNode equals, ExpressionNode newValue);
class ExpressionStatement : StatementNode, this(ExpressionNode expr);
class ReturnStatement : StatementNode, this(TokenNode returnKeyword, ExpressionNode value);
class BlockNode : StatementNode, this(TokenNode lsquirly, Span<StatementNode> statements, TokenNode rsquirly);
class IfStatement : StatementNode, this(TokenNode ifToken, ExpressionNode condition, StatementNode ifBlock, TokenNode elseToken, StatementNode elseBlock);

class ExternalInvokation : StatementNode, this(Library lib, int id);
