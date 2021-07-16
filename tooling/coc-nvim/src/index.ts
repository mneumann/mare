import * as child_process from "child_process";
import {
  commands,
  Disposable,
  ExtensionContext,
  Uri,
  workspace,
  LanguageClient,
  LanguageClientOptions,
} from "coc.nvim";

import {
  TextDocument,
  WorkspaceFolder,
  WorkspaceFoldersChangeEvent,
} from "vscode-languageserver-protocol";

const clients: Map<Uri, SaviClient> = new Map();

export async function activate(ctx: ExtensionContext) {
  workspace.onDidOpenTextDocument((doc) => didOpenTextDocument(doc, ctx));
  workspace.textDocuments.forEach((doc) => didOpenTextDocument(doc, ctx));
  workspace.onDidChangeWorkspaceFolders((e) =>
    didChangeWorkspaceFolders(e, ctx)
  );
}

export async function deactivate() {
  return Promise.all([...clients.values()].map((ws) => ws.stop()));
}

import * as tmp from "tmp";

function didOpenTextDocument(document: TextDocument, ctx: ExtensionContext) {
  // Ignore text documents whose language isn't Savi.
  if (document.languageId !== "savi") return;

  // Ignore text documents with no workspace folder associated.
  let folder = workspace.getWorkspaceFolder(document.uri);
  if (!folder) return;

  // Ignore workspace folders we're already tracking.
  if (clients.has(Uri.parse(folder.uri))) return;

  // Add a client for the new workspace folder.
  const client = new SaviClient(folder);
  clients.set(Uri.parse(folder.uri), client);
  client.start(ctx);
}

function didChangeWorkspaceFolders(
  e: WorkspaceFoldersChangeEvent,
  ctx: ExtensionContext
) {
  // Add a client for each workspace folder that is new.
  for (const folder of e.added) {
    if (!clients.has(Uri.parse(folder.uri))) {
      const client = new SaviClient(folder);
      clients.set(Uri.parse(folder.uri), client);
      client.start(ctx);
    }
  }

  // Clean up clients for workspace folders that were closed.
  for (const folder of e.removed) {
    const ws = clients.get(Uri.parse(folder.uri));
    if (ws) {
      clients.delete(Uri.parse(folder.uri));
      ws.stop();
    }
  }
}

class SaviClient {
  private disposables: Disposable[] = [];
  private client: LanguageClient | null = null;
  private readonly folder: WorkspaceFolder;

  constructor(folder: WorkspaceFolder) {
    this.folder = folder;
  }

  private get clientOptions(): LanguageClientOptions {
    return {
      documentSelector: [
        { language: "savi", scheme: "file" },
        { language: "savi", scheme: "untitled" },
      ],
      diagnosticCollectionName: "savi",
      synchronize: { configurationSection: "savi" },
      initializationOptions: {
        omitInitBuild: true,
        cmdRun: true,
      },
      workspaceFolder: this.folder,
    };
  }

  public async start(ctx: ExtensionContext) {
    this.client = new LanguageClient(
      "savi-client",
      "Savi Language Server",
      async () => {
        return this.spawnServer();
      },
      this.clientOptions
    );

    this.disposables.push(
      commands.registerCommand("savi.update", async () => {
        this.updateImage();
        await this.stop();
        return this.start(ctx);
      })
    );

    this.disposables.push(
      commands.registerCommand("savi.restart", async () => {
        await this.stop();
        return this.start(ctx);
      })
    );

    this.disposables.push(this.client.start());
    await this.client.onReady();
  }

  public async stop() {
    if (this.client) await this.client.stop();

    this.disposables.forEach((d) => d.dispose());
  }

  private async spawnServer(): Promise<child_process.ChildProcess> {
    const cwd = Uri.parse(this.folder.uri).fsPath;
    const env = { ...process.env };

    const tmpDir = tmp.dirSync().name;

    let serverProcess = child_process.spawn(
      "docker",
      [
        "run",
        "-i",
        "--rm",
        "-v",
        `${cwd}:/opt/code`,
        "-v",
        `${tmpDir}:/opt/host_std`,
        "-e",
        `SOURCE_DIRECTORY_MAPPING=${cwd}:/opt/code`,
        "-e",
        `STD_DIRECTORY_MAPPING=${tmpDir}:/opt/host_std`,
        "jemc/savi",
        "server",
      ],
      { env, cwd }
    );

    serverProcess.on("error", (err: { code?: string; message: string }) => {
      workspace.showMessage(
        `Failed to spawn Savi Language Server: \`${err.message}\``
      );
    });

    return serverProcess;
  }

  private async updateImage() {
    const cwd = Uri.parse(this.folder.uri).fsPath;
    const env = { ...process.env };

    let updateProcess = child_process.spawn("docker", ["pull", "jemc/savi"], {
      env,
      cwd,
    });

    const channel = workspace.createOutputChannel("Savi Updater");
    workspace.showMessage(
      "Pulling latest image for the Savi Language Server",
      "more"
    );
    channel.show();

    updateProcess.on("error", (err: { code?: string; message: string }) => {
      workspace.showMessage(
        `Failed to update Savi Language Server: \`${err.message}\``,
        "error"
      );
    });

    updateProcess.on("exit", (code) => {
      if (code == 0) {
        workspace.showMessage(
          "Finished pulling latest image for the Savi Language Server",
          "more"
        );
        channel.dispose();
      } else {
        workspace.showMessage("Failed to update Savi Language Server", "error");
      }
    });

    updateProcess.stdout.on("data", (chunk) => {
      channel.append(chunk.toString());
    });

    return updateProcess;
  }
}
