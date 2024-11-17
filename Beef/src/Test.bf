using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Monkey;

static
{
	[Test]
	static void TestLexer()
	{
		const let input = @"""
			/* comment */
			let a = 3;
			if ("'69\n" == '\'69\n')
			{
				// comment
			}
			""";
		Token?[?] expected = .(
			.Let, null, .Assign, null, .Semicolon,
			.If, .LParen, null, .Equal, null, .RParen,
			.LSquirly, .RSquirly, .EOF
		);

		Source source = scope .(
			scope .(scope StringStream(input, .Reference)),
			"TestLexer.input",
			scope ConsoleErrors(),
			scope BumpAllocator()
		);

		int nullI = 0;
		for (let exp in expected)
		{
			let next = source.ParseNext().Value;
			if (let token = next as TokenNode)
			{
				Test.Assert(exp != null);
				Test.Assert(exp case token.token, scope $"{exp} case {token.token}");
				if (exp case .EOF) break;
			}
			else
			{
				Test.Assert(exp == null);
				switch (nullI++)
				{
				case 0:
					let identifier = next as IdentifierNode;
					Test.Assert(identifier != null);
					Test.Assert(identifier.identifier == "a");
				case 1:
					let int = next as IntLiteral;
					Test.Assert(int != null);
					Test.Assert(int.value == 3);
				case 2, 3:
					let string = next as StringLiteral;
					Test.Assert(string != null);
					Test.Assert(string.value == "'69\n");
				default:
					Test.FatalError();
				}
			}
		}
	}

	[Test]
	static void TestParser()
	{
		const let input = """
			{
				let a = 0;
				a = (a + 1) * 2;
				a = a + 1 * 3;
				if (a == 5) {
					// ...
				} else {
					// ...
				}
				let people = [{"name": "Anna", "age": 24}, {"name": "Bob", "age": 99}];

				let puts = fn (text) {
					return;
				};
				puts(people[0]["name"]);
			}
			""";

		Source source = scope .(
			scope .(scope StringStream(input, .Reference)),
			"TestParser.input",
			scope ConsoleErrors(),
			scope BumpAllocator()
		);

		Parser parser = scope .(source);
#unwarn
		let output = parser.NextStatement().Value;
		//Debug.Break();
	}

	[Test]
	static void TestInterpreter()
	{
		const let input = """
			puts("hi");

			let a = 0;
			a = (a + 1) * 3; // 3
			a = a + 2; // 5
			assert(a == 5);
			
			let b = true;
			let toggle = fn () {
				if (b)
					b = false;
				else
					b = true;
				!b
			};
			toggle(); // false
			b = toggle(); // false
			assert(!b);

			let array = [6, 9, [], '!'];
			let result = "";
			map(array, fn (item) {
				result = result + item;
			});
			assert(result == "69[]!");

			let make_greeting = fn (addressed) {
				return fn () {
					"Hello, " + addressed
				};
			};
			assert(make_greeting("World")() == "Hello, World");
			""";

		Source source = scope .(
			scope .(scope StringStream(input, .Reference)),
			"TestInterpreter.input",
			scope ConsoleErrors(),
			scope BumpAllocator()
		);
		Parser parser = scope .(source);
		Interpreter interp = scope .(parser);

		interp.ScopeIn();
		scope CoreLibrary().Init(interp);
		interp.Execute(parser.ParseToEnd());
		Debug.Break();
		interp.ScopeOut();
	}
}
