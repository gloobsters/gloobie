namespace RenderiteGenerator;

public static class QueueExtensions
{
    public static T DequeueLast<T>(this Queue<T> queue)
    {
        while (queue.Count != 1)
        {
            _ = queue.Dequeue();
        }

        return queue.Dequeue();
    }
}