<script lang="ts">
  // Agent settings (the ACP-configuration dialog): which harness command
  // Valea runs, plus the same three diagnostics the chat route's doctor
  // fallback shows. Claude Code is the built-in harness today; the custom
  // command field is the escape hatch for a differently-installed adapter
  // (absolute path, extra flags) or another ACP-speaking harness.
  //
  // Trust model: the command lives in trusted app config
  // (`Valea.App.Config`), and SAVING HERE IS THE CONSENT STEP — the
  // `set_harness_command` RPC persists and approves in one gesture, which
  // is safe precisely because only this control-token-gated UI can call it
  // (an opened folder or an agent session never can; the launch surface
  // carries no RPC endpoint or token).
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import DoctorPanel from './DoctorPanel.svelte';
  import { api } from '$lib/api/client';

  let { open = $bindable(false) }: { open?: boolean } = $props();

  type HarnessConfig = {
    command: string[];
    approved: boolean;
    isDefault: boolean;
    defaultCommand: string[];
  };

  let config = $state<HarnessConfig | null>(null);
  let commandText = $state('');
  let loading = $state(false);
  let saving = $state(false);
  let error = $state<string | null>(null);
  let savedFlash = $state(false);

  const dirty = $derived(config !== null && commandText.trim() !== config.command.join(' '));

  async function load(): Promise<void> {
    loading = true;
    error = null;
    const result = await api.harnessConfig();
    if (result.ok) {
      config = result.data as HarnessConfig;
      commandText = config.command.join(' ');
    } else {
      error = "Couldn't load the harness settings. Try again in a moment.";
    }
    loading = false;
  }

  $effect(() => {
    if (open) {
      savedFlash = false;
      void load();
    }
  });

  // Whitespace-split argv. Deliberately no quoting/shell grammar — the
  // command is executed directly (never through a shell), and a path with
  // spaces is the rare case a future picker can serve better than an
  // escaping syntax nobody can discover.
  function parsedCommand(): string[] {
    return commandText.split(/\s+/).filter((part) => part.length > 0);
  }

  async function save(): Promise<void> {
    const command = parsedCommand();
    if (command.length === 0) {
      error = 'Enter a command to run, or reset to the default.';
      return;
    }
    saving = true;
    error = null;
    const result = await api.setHarnessCommand(command);
    if (result.ok) {
      config = result.data as HarnessConfig;
      commandText = config.command.join(' ');
      savedFlash = true;
      setTimeout(() => (savedFlash = false), 2000);
    } else {
      error = "Couldn't save the command. Check it and try again.";
    }
    saving = false;
  }

  async function resetToDefault(): Promise<void> {
    if (!config) return;
    commandText = config.defaultCommand.join(' ');
    await save();
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="max-h-[85vh] overflow-y-auto sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Agent settings</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        Valea runs your own agent as a separate program and stays the approval layer around it.
        Claude Code is the built-in harness today.
      </Dialog.Description>
    </Dialog.Header>

    {#if loading && !config}
      <p class="text-ink-meta text-[13px]">Loading…</p>
    {:else}
      <div class="flex flex-col gap-2">
        <Label for="harness-command" class="text-[13px]">Harness command</Label>
        <Input
          id="harness-command"
          bind:value={commandText}
          spellcheck={false}
          autocomplete="off"
          class="font-mono text-[12.5px]"
          placeholder={config ? config.defaultCommand.join(' ') : ''}
        />
        <p class="text-ink-meta text-[12px]">
          {#if config?.isDefault && !dirty}
            Using the built-in Claude Code adapter from your PATH.
          {:else}
            Runs directly (no shell). Only commands you save here are ever executed — nothing in a
            project folder can change this.
          {/if}
        </p>
        <div class="flex items-center gap-2">
          <Button type="button" size="sm" onclick={() => void save()} disabled={saving || !dirty}>
            {saving ? 'Saving…' : 'Save harness'}
          </Button>
          {#if config && !config.isDefault}
            <Button type="button" variant="outline" size="sm" onclick={() => void resetToDefault()} disabled={saving}>
              Reset to Claude Code
            </Button>
          {/if}
          {#if savedFlash}
            <span class="text-act-dot text-[12px]">Saved</span>
          {/if}
        </div>
        {#if error}
          <p class="text-warn-ink text-[12.5px]" role="alert">{error}</p>
        {/if}
      </div>

      <div class="border-paper-hairline mt-4 border-t pt-4">
        <p class="text-overline mb-1">Diagnostics</p>
        <p class="text-ink-body mb-1 text-[12.5px]">
          Three checks against the harness this app will actually launch.
        </p>
        <DoctorPanel showIntro={false} />
      </div>
    {/if}
  </Dialog.Content>
</Dialog.Root>
