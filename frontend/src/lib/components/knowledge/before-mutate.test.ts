import { describe, it, expect, vi } from 'vitest';
import { withBeforeMutate } from './before-mutate';

describe('withBeforeMutate', () => {
  it('awaits onBeforeMutate to completion before running the mutate call', async () => {
    const order: string[] = [];

    const onBeforeMutate = vi.fn(async () => {
      order.push('flush:start');
      await new Promise((resolve) => setTimeout(resolve, 5));
      order.push('flush:end');
    });

    const run = vi.fn(async () => {
      order.push('mutate');
      return { ok: true as const };
    });

    const result = await withBeforeMutate(onBeforeMutate, run);

    expect(order).toEqual(['flush:start', 'flush:end', 'mutate']);
    expect(result).toEqual({ ok: true });
  });

  it('runs the mutate call directly when onBeforeMutate is undefined (rows for other pages)', async () => {
    const run = vi.fn(async () => 'done');

    const result = await withBeforeMutate(undefined, run);

    expect(run).toHaveBeenCalledTimes(1);
    expect(result).toBe('done');
  });

  it('propagates a failing onBeforeMutate without running the mutate call', async () => {
    const onBeforeMutate = vi.fn(async () => {
      throw new Error('flush failed');
    });
    const run = vi.fn(async () => 'done');

    await expect(withBeforeMutate(onBeforeMutate, run)).rejects.toThrow('flush failed');
    expect(run).not.toHaveBeenCalled();
  });
});
