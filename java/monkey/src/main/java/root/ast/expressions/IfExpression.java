package root.ast.expressions;

import root.LocalizedToken;
import root.Token;
import root.ast.statements.BlockStatement;

public class IfExpression extends Expression {

    private Expression condition;
    private BlockStatement consequence;
    private BlockStatement alternative;

    public IfExpression(LocalizedToken token) {
        this.token = token;
    }

    public Expression getCondition() {
        return condition;
    }

    public void setCondition(Expression condition) {
        this.condition = condition;
    }

    public BlockStatement getConsequence() {
        return consequence;
    }

    public void setConsequence(BlockStatement consequence) {
        this.consequence = consequence;
    }

    public BlockStatement getAlternative() {
        return alternative;
    }

    public void setAlternative(BlockStatement alternative) {
        this.alternative = alternative;
    }

    @Override
    public String toString() {
        var ifString = "if (%s) %s".formatted(condition, consequence);

        if (alternative != null) {
            ifString += " else %s".formatted(alternative);
        }

        return ifString;
    }
}
