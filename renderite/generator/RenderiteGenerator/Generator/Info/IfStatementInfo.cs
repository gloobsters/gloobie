using Mono.Cecil.Cil;
using RenderiteGenerator.Generator.Blocks;

namespace RenderiteGenerator.Generator.Info;

public class IfStatementInfo : IDisposable
{
    public IfStatementInfo(Block ifBlock, Instruction jumpDestination)
    {
        IfBlock = ifBlock;
        JumpDestination = jumpDestination;
    }

    public readonly Block IfBlock;
    public readonly Instruction JumpDestination;
    
    public void Dispose()
    {
        IfBlock.Dispose();
    }
}