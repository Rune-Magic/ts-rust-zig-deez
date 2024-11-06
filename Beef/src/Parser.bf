using System;
using System.Collections;
using System.Diagnostics;

namespace Monkey;

class Parser
{
	protected Source source;
	protected IRawAllocator alloc;
	protected IErrorOutput output;

	protected Queue<HashSet<StringView>> functionCaputres;
	protected Queue<HashSet<StringView>> nativeVars;

	public Source Source
	{
		get => source;
		set
		{
			source = value;
			alloc = value.alloc;
			output = value.output;
		}
	}

	public this(Source source)
	{
		Source = source;
		functionCaputres = new:alloc .(4) { new:alloc .(2) };
		nativeVars = new:alloc .(4) { new:alloc .(4) };
	}

	public Result<StatementNode> NextStatement()
	{
		let next = Try!(source.ParseNext());
		if (let token = next as TokenNode)
			switch (token.token)
			{
			case .Let:
				let identifier = Try!(source.ExpectIdentifier());
				let assign = Try!(source.ExpectToken(.Assign));
				let expr = Try!(NextExpression(true));
				let semicolon = Try!(source.ExpectToken(.Semicolon));
				if (!nativeVars.Back.Add(identifier.identifier))
				{
					output.Fail(identifier.position, $"Variable '{identifier.identifier}' already exists");
					return .Err;
				}	 
				return new:alloc LetStatement(token, identifier, assign, expr) { position = .(token.position.Start, semicolon.position.End), semicolon = semicolon };
			case .Return:
				ExpressionNode expr = null;
				if (!Try!(source.NextTokenCase(.Semicolon, var semicolon)))
				{
					expr = Try!(NextExpression(true));
					semicolon = Try!(source.ExpectToken(.Semicolon));
				}
				return new:alloc ReturnStatement(token, expr) { position = .(token.position.Start, semicolon.position.End), semicolon = semicolon };
			case .LSquirly:
				List<StatementNode> statements = new:alloc .(8);
				TokenNode rsquirlyToken;
				while (true)
				{
					let rsquirly = Try!(source.ParseNext());
					rsquirlyToken = rsquirly as TokenNode;
					if (rsquirlyToken != null && rsquirlyToken.token == .RSquirly)
						break;
					source.Cycle(rsquirly);
					statements.Add(Try!(NextStatement()));
				}
				return new:alloc BlockNode(token, statements, rsquirlyToken) { position = .(token.position.Start, rsquirlyToken.position.End), semicolon = null };
			case .If:
				Try!(source.ExpectToken(.LParen));
				let condition = Try!(NextExpression(true));
				Try!(source.ExpectToken(.RParen));
				let ifBlock = Try!(NextStatement());
				IfStatement statement = new:alloc .(token, condition, ifBlock, null, null);
				let else_ = Try!(source.ParseNext());
				let elseToken = else_ as TokenNode;
				if (elseToken != null && elseToken.token == .Else)
				{
					statement.elseToken = elseToken;
					statement.elseBlock = Try!(NextStatement());
				}	
				else
					source.Cycle(else_);
				return statement;
			default:
			}

		do
		{
			if (let identifier = next as IdentifierNode)
			{
				let assign = Try!(source.NextToken());
				if (assign.token != .Assign)
				{
					source..Cycle(identifier)..Cycle(assign);
					break;
				}
				let expr = Try!(NextExpression(true));
				let semicolon = Try!(source.ExpectToken(.Semicolon));
				return new:alloc ReassignStatement(identifier, assign, expr) { position = .(identifier.position.Start, semicolon.position.End), semicolon = semicolon };
			}
			source.Cycle(next);
		}

		let expr = Try!(NextExpression(true));
		let nextToken = Try!(source.NextToken());
		switch (nextToken.token)
		{
		case .Semicolon:
			return new:alloc ExpressionStatement(expr) { position = .(expr.position.Start, nextToken.position.End), semicolon = nextToken };
		case .RSquirly:
			source.Cycle(nextToken);
			return new:alloc ReturnStatement(null, expr) { position = expr.position, semicolon = null };
		default:
			output.Fail(nextToken.position, $"Expected semicolon");
			return .Err;
		}
	}

	public Result<ExpressionNode> NextExpression(bool allowOperations)
	{
		if (allowOperations)
		{
			var lhs = Try!(NextExpression(false));
			while (true)
			{
				let next = Try!(source.NextTokenOrIdentifier());
				let token = next as TokenNode;
				if (token != null)
					switch (token.token)
					{
					case .Plus, .Dash, .ForwardSlash, .Asterisk, .Equal, .NotEqual, .LessThan, .GreaterThan, .ConditionalAnd, .ConditionalOr:
						let rhs = Try!(NextExpression(false));
						lhs = new:alloc OperationExpression(lhs, token, rhs) { position = .(lhs.position.Start, rhs.position.End) };
						continue;
					default:
					}

				int Weigh(TokenNode t)
				{
					switch (t.token)
					{
					case .Plus, .Dash: return 0;
					case .ForwardSlash, .Asterisk: return 1;
					case .Equal, .NotEqual, .LessThan, .GreaterThan: return 2;
					case .ConditionalAnd, .ConditionalOr: return 3;
					default: Runtime.FatalError();
					}
				}

				ExpressionNode Order(ExpressionNode node)
				{
					let operation = node as OperationExpression;
					if (operation == null) return node;
					let first = operation.lhs as OperationExpression;
					if (first == null) return node;
					if (Weigh(first.operation) >= Weigh(operation.operation))
					{
						operation.rhs = Order(operation.rhs);
						return operation;
					}
					let ordered = Order(operation.rhs);
					return new:alloc OperationExpression(
						first.lhs, first.operation,
						new:alloc OperationExpression(first.rhs, operation.operation, ordered) { position = .(first.lhs.position.Start, ordered.position.End) }
					) { position = .(first.lhs.position.Start, ordered.position.End) };
				}

				source.Cycle(token);
				return Order(lhs);
			}
		}

		defer
		{
			mixin Try(var result)
			{
				if (result case .Err)
				{
					@return = .Err;
					break qualify;
				}
				result.Value
			}

			if (@return case .Ok)
				qualify: while (true) switch (source.ParseNext())
				{
				case .Err:
					@return = .Err;
				case .Ok(let val):
					let t = val as TokenNode;
					if (t == null)
					{
						source.Cycle(val);
						break qualify;
					}
					switch (t.token)
					{
					case .LParen:
						List<ExpressionNode> arguments = new:alloc .();
						if (!Try!(source.NextTokenCase(.RParen, var rparenth)))
							loop2: while (true)
							{
								arguments.Add(Try!(NextExpression(true)));
								rparenth = Try!(source.NextToken());
								switch (rparenth.token)
								{
								case .RParen: break loop2;
								case .Comma: continue;
								default:
									output.Fail(rparenth.position, "Expected ',' or ')'");
									@return = .Err;
								}
							}
						@return = new:alloc InvokationExpression(@return, t, arguments, rparenth) { position = .(@return->position.Start, rparenth.position.End) };
					case .LBracket:
						let index = Try!(NextExpression(true));
						let rBracket = Try!(source.ExpectToken(.RBracket));
						@return = new:alloc IndexExpression(@return, t, index, rBracket) { position = .(@return->position.Start, rBracket.position.End) };
					default:
						source.Cycle(val);
						break qualify;
					}
				}
		}

		var next = Try!(source.ParseNext());
		if (let token = next as TokenNode)
			switch (token.token)
			{
			case .LParen:
				let expr = Try!(NextExpression(true));
				let closing = Try!(source.ExpectToken(.RParen));
				return new:alloc EncaupsulatedExpression(token, expr, closing) { position = .(token.position.Start, closing.position.End) };
			case .Bang:
				let expr = Try!(NextExpression(false));
				return new:alloc NegationExpression(token, expr) { position = .(token.position.Start, expr.position.End) };
			case .LBracket:
				List<ExpressionNode> values = new:alloc .(4);
				if (!Try!(source.NextTokenCase(.RBracket, var rbracket)))
					loop: while (true)
					{
						values.Add(Try!(NextExpression(true)));
						rbracket = Try!(source.NextToken());
						switch (rbracket.token)
						{
						case .RBracket: break loop;
						case .Comma: continue;
						default:
							output.Fail(rbracket.position, "Expected ',' or ']'");
							return .Err;
						}
					}
				return new:alloc ArrayExpression(token, values, rbracket) { position = .(token.position.Start, rbracket.position.End) };
			case .LSquirly:
				List<ExpressionNode> keys = new:alloc .(4);
				List<ExpressionNode> values = new:alloc .(4);
				if (!Try!(source.NextTokenCase(.RSquirly, var rsquirly)))
					loop: while (true)
					{
						keys.Add(Try!(NextExpression(true)));
						Try!(source.ExpectToken(.Colon));
						values.Add(Try!(NextExpression(true)));
						rsquirly = Try!(source.NextToken());
						switch (rsquirly.token)
						{
						case .RSquirly: break loop;
						case .Comma: continue;
						default:
							output.Fail(rsquirly.position, "Expected ',' or '}'");
							return .Err;
						}
					}
				return new:alloc DictExpression(token, keys, values, rsquirly) { position = .(token.position.Start, rsquirly.position.End) };
			case .Function:
				Try!(source.ExpectToken(.LParen));
				List<IdentifierNode> parameters = new:alloc .();
				if (!Try!(source.NextTokenCase(.RParen, var rparen)))
					loop: while (true)
					{
						let identifier = Try!(source.ExpectIdentifier());
						for (let par in parameters)
							if (par.identifier == identifier.identifier)
							{
								output.Fail(identifier.position, "Duplicate parameter");
								return .Err;
							}
						parameters.Add(identifier);
						rparen = Try!(source.NextToken());
						switch (rparen.token)
						{
						case .RParen: break loop;
						case .Comma: continue;
						default:
							output.Fail(rparen.position, "Expected ',' or ')'");
							return .Err;
						}
					}
				source.Cycle(Try!(source.ExpectToken(.LSquirly)));
				functionCaputres.Add(new .(5));
				nativeVars.Add(new .(5));
				let block = Try!(NextStatement()) as BlockNode;
				Debug.Assert(block != null);
				let back = functionCaputres.PopBack(); defer delete back;
				delete nativeVars.PopBack();
				return new:alloc FunctionExpression(token, parameters, block, back.CopyTo(..new:alloc StringView[back.Count])) { position = .(token.position.Start, block.position.End) };
			default:
				output.Fail(token.position, $"Unexpected {token.token}");
				return .Err;
			}	
		if (next is StringLiteral || next is IntLiteral || next is BoolLiteral)
			return next as ExpressionNode;
		if (let identifier = next as IdentifierNode)
		{
			if (!nativeVars.Back.Contains(identifier.identifier))
				functionCaputres.Back.Add(identifier.identifier);
			return new:alloc VariableExpression(identifier) { position = identifier.position };
		}

		Runtime.FatalError();
	}
}
