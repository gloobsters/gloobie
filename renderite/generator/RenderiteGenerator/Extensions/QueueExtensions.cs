using RenderiteGenerator.Generator;

namespace RenderiteGenerator.Extensions;

public static class QueueExtensions
{
    public static string DequeueLastHumanizeField(this Queue<string> queue)
    {
        return queue.DequeueLastGeneric().HumanizeField();
    }
    
    public static T DequeueLastGeneric<T>(this Queue<T> queue)
    {
        while (queue.Count != 1)
        {
            _ = queue.Dequeue();
        }

        return queue.Dequeue();
    }
}