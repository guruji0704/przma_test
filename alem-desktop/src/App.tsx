import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { confirm } from "@tauri-apps/plugin-dialog";

// ── Types ──────────────────────────────────────────────────────────────────
interface Doc {
  id: string;
  filename: string;
  text_content: string;
  is_synced: number;
  status: string;
  created_at: string;
  updated_at: string;
  content_type: string;
  version: number;
  conflict_copy_of: string | null;
}

interface SyncStatus {
  pending: number;
  synced: number;
  failed: number;
  total: number;
}

interface Toast {
  id: number;
  msg: string;
  type: "info" | "success" | "error";
}

interface CaptchaResponse {
  answer_data: string;
  token: string;
  type: string;
  seconds_valid: number;
}

interface RegisterResponse {
  success: boolean;
  user_id: string | null;
  email: string | null;
  message: string;
}

interface LoginResponse {
  success: boolean;
  did: string | null;
  access_token: string | null;
}

interface GenericResponse {
  success: boolean;
  message: string;
}

// ── Styles ─────────────────────────────────────────────────────────────────
const css = `
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap');

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body, html, #root {
    height: 100%;
    background: #0A0E27;
    color: #F0F4F8;
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    font-size: 14px;
    line-height: 1.6;
    overflow: hidden;
  }

  .app {
    display: grid;
    grid-template-columns: 260px 1fr;
    grid-template-rows: 60px 1fr;
    height: 100vh;
  }

  .header {
    grid-column: 1 / -1;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 32px;
    border-bottom: 1px solid #1E3A5F;
    background: linear-gradient(135deg, #0A0E27 0%, #141B2D 100%);
    box-shadow: 0 2px 8px rgba(0,0,0,0.3);
  }

  .logo {
    font-size: 20px;
    font-weight: 700;
    letter-spacing: -0.5px;
    background: linear-gradient(135deg, #4A9EFF 0%, #FFB800 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 20px;
    font-size: 12px;
    color: #94A9C9;
  }

  .sync-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    display: inline-block;
    margin-right: 8px;
  }
  .sync-dot.online  { background: #00E0C6; box-shadow: 0 0 12px rgba(0,224,198,0.8); animation: pulse 2s infinite; }
  .sync-dot.offline { background: #FF6B6B; box-shadow: 0 0 8px rgba(255,107,107,0.5); }

  @keyframes pulse {
    0%,100% { opacity:1; transform:scale(1); }
    50%      { opacity:0.7; transform:scale(0.95); }
  }

  .sidebar {
    border-right: 1px solid #1E3A5F;
    background: linear-gradient(180deg, #141B2D 0%, #0F1520 100%);
    padding: 24px 16px;
    overflow-y: auto;
    box-shadow: 2px 0 12px rgba(0,0,0,0.2);
  }

  .nav-item {
    padding: 12px 16px;
    margin-bottom: 6px;
    cursor: pointer;
    border-radius: 8px;
    transition: all 0.2s cubic-bezier(0.4,0,0.2,1);
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-weight: 500;
    color: #94A9C9;
    border: 1px solid transparent;
  }
  .nav-item:hover { background: rgba(74,158,255,0.1); color: #F0F4F8; border-color: rgba(74,158,255,0.3); }
  .nav-item.active { background: linear-gradient(135deg,rgba(74,158,255,0.2) 0%,rgba(255,184,0,0.1) 100%); color: #4A9EFF; border-color: #4A9EFF; box-shadow: 0 4px 12px rgba(74,158,255,0.2); }

  .badge { background: #FF6B6B; color:#fff; padding: 3px 9px; font-size:11px; font-weight:600; border-radius:12px; box-shadow: 0 2px 6px rgba(255,107,107,0.4); }

  .main { overflow-y: auto; background: #0A0E27; }

  .panel { padding: 32px; max-width: 1200px; }

  .panel-title {
    font-size: 28px; font-weight: 700; margin-bottom: 6px; letter-spacing: -0.5px;
    background: linear-gradient(135deg, #F0F4F8 0%, #94A9C9 100%);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text;
  }
  .panel-sub { color:#94A9C9; font-size:13px; margin-bottom:32px; }

  .card { border:1px solid #1E3A5F; padding:24px; margin-bottom:20px; background:linear-gradient(135deg,#141B2D 0%,#0F1520 100%); border-radius:12px; box-shadow:0 4px 12px rgba(0,0,0,0.2); }

  .doc-list { display:flex; flex-direction:column; gap:12px; }

  .doc-item {
    border:1px solid #1E3A5F; padding:16px;
    display:flex; align-items:center; justify-content:space-between;
    background:linear-gradient(135deg,#141B2D 0%,#0F1520 100%);
    border-radius:10px; transition:all 0.2s;
  }
  .doc-item:hover { border-color:#4A9EFF; background:rgba(74,158,255,0.05); transform:translateX(4px); }

  .doc-info { flex:1; min-width:0; }
  .doc-name { font-weight:600; margin-bottom:4px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; color:#F0F4F8; }
  .doc-meta { font-size:12px; color:#94A9C9; font-family:'JetBrains Mono',monospace; }
  .doc-conflict { color: #FF6B6B; font-size: 11px; margin-left: 8px; font-weight: 600; }

  .doc-status { display:flex; align-items:center; gap:12px; }

  .tag { font-size:10px; padding:5px 12px; font-weight:600; text-transform:uppercase; letter-spacing:0.5px; border-radius:6px; font-family:'JetBrains Mono',monospace; }
  .tag-synced  { background:#00E0C6; color:#0A0E27; box-shadow:0 2px 8px rgba(0,224,198,0.3); }
  .tag-pending { background:#FFB800; color:#0A0E27; box-shadow:0 2px 8px rgba(255,184,0,0.3); }
  .tag-failed  { background:#FF6B6B; color:#fff;    box-shadow:0 2px 8px rgba(255,107,107,0.3); }

  .btn {
    padding:12px 20px; border:1px solid #1E3A5F; background:transparent;
    color:#F0F4F8; font-family:'Inter',sans-serif; font-size:13px; font-weight:600;
    cursor:pointer; transition:all 0.2s cubic-bezier(0.4,0,0.2,1); border-radius:8px;
  }
  .btn:hover { background:#4A9EFF; border-color:#4A9EFF; color:#fff; transform:translateY(-2px); box-shadow:0 6px 20px rgba(74,158,255,0.4); }
  .btn:active { transform:translateY(0); }
  .btn:disabled { opacity:0.4; cursor:not-allowed; transform:none; }

  .btn-danger { border-color:#FF6B6B; color:#FF6B6B; }
  .btn-danger:hover { background:#FF6B6B; border-color:#FF6B6B; color:#fff; box-shadow:0 6px 20px rgba(255,107,107,0.4); }

  .btn-secondary { background:#1E3A5F; border-color:#1E3A5F; }
  .btn-secondary:hover { background:#2A4A75; border-color:#2A4A75; box-shadow:0 6px 20px rgba(30,58,95,0.4); }

  .btn-success { border-color:#00E0C6; color:#00E0C6; }
  .btn-success:hover { background:#00E0C6; border-color:#00E0C6; color:#0A0E27; box-shadow:0 6px 20px rgba(0,224,198,0.4); }

  .input {
    width:100%; padding:12px 16px; background:#0A0E27; border:1px solid #1E3A5F;
    color:#F0F4F8; font-family:'Inter',sans-serif; font-size:14px; outline:none;
    margin-bottom:16px; border-radius:8px; transition:all 0.2s;
  }
  .input:focus { border-color:#4A9EFF; box-shadow:0 0 0 3px rgba(74,158,255,0.15); }
  .input::placeholder { color:#94A9C9; opacity:0.5; }
  textarea.input { resize:vertical; font-family:'JetBrains Mono',monospace; line-height:1.6; }

  .empty { text-align:center; padding:64px; color:#94A9C9; border:2px dashed #1E3A5F; border-radius:12px; background:rgba(30,58,95,0.1); }
  .empty-icon { font-size:56px; margin-bottom:16px; opacity:0.3; }

  .toast-container { position:fixed; bottom:24px; right:24px; display:flex; flex-direction:column; gap:12px; z-index:999; }

  .toast {
    padding:14px 18px; border:1px solid #1E3A5F; background:#141B2D;
    font-size:13px; animation:slideIn 0.3s cubic-bezier(0.4,0,0.2,1);
    min-width:300px; border-radius:10px; box-shadow:0 8px 32px rgba(0,0,0,0.4);
    backdrop-filter:blur(10px);
  }
  .toast.error   { border-color:#FF6B6B; background:rgba(255,107,107,0.15); color:#FF6B6B; box-shadow:0 8px 32px rgba(255,107,107,0.3); }
  .toast.success { border-color:#00E0C6; background:rgba(0,224,198,0.15);   color:#00E0C6; box-shadow:0 8px 32px rgba(0,224,198,0.3); }
  .toast.info    { border-color:#FFB800; background:rgba(255,184,0,0.15);    color:#FFB800; box-shadow:0 8px 32px rgba(255,184,0,0.3); }

  @keyframes slideIn {
    from { transform:translateX(30px); opacity:0; }
    to   { transform:translateX(0);    opacity:1; }
  }

  .fullscreen {
    height:100vh;
    display:flex;
    align-items:center;
    justify-content:center;
    background:linear-gradient(135deg,#0A0E27 0%,#141B2D 100%);
    color:#F0F4F8;
  }

  .boot-logo {
    font-size:72px; font-weight:700; letter-spacing:-2px; margin-bottom:40px;
    background:linear-gradient(135deg,#4A9EFF 0%,#FFB800 100%);
    -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;
    animation:pulse 2s infinite;
  }

  .boot-steps { display:flex; flex-direction:column; gap:12px; font-size:14px; color:#94A9C9; }

  .auth-container { max-width:480px; width:100%; padding:48px; }

  .auth-title {
    font-size:42px; font-weight:700; margin-bottom:8px; letter-spacing:-1px;
    background:linear-gradient(135deg,#4A9EFF 0%,#FFB800 100%);
    -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;
  }
  .auth-sub { color:#94A9C9; font-size:14px; margin-bottom:40px; }

  .auth-tabs {
    display:flex;
    gap:0;
    margin-bottom:32px;
    border:1px solid #1E3A5F;
    border-radius:8px;
    overflow:hidden;
  }
  .auth-tab {
    flex:1;
    padding:10px;
    text-align:center;
    cursor:pointer;
    font-size:13px;
    font-weight:600;
    color:#94A9C9;
    background:transparent;
    border:none;
    transition:all 0.2s;
  }
  .auth-tab.active {
    background:linear-gradient(135deg,rgba(74,158,255,0.2),rgba(255,184,0,0.1));
    color:#4A9EFF;
  }

  .captcha-box {
    border:1px solid #1E3A5F; padding:24px;
    background:linear-gradient(135deg,#141B2D 0%,#0F1520 100%);
    margin-bottom:24px; border-radius:12px;
  }
  .captcha-label { font-size:11px; color:#94A9C9; margin-bottom:12px; text-transform:uppercase; letter-spacing:0.5px; font-weight:500; }
  .captcha-code { font-size:36px; font-weight:700; letter-spacing:4px; font-family:'JetBrains Mono',monospace; color:#4A9EFF; text-shadow:0 0 20px rgba(74,158,255,0.5); }

  .btn-group { display:flex; gap:12px; }
  .btn-group .btn { flex:1; }

  .did-box {
    border:1px solid #1E3A5F; padding:16px; background:#0A0E27;
    word-break:break-all; font-size:12px; line-height:1.8; margin:20px 0;
    border-radius:10px; font-family:'JetBrains Mono',monospace; color:#4A9EFF;
    box-shadow:inset 0 2px 8px rgba(0,0,0,0.3);
  }

  .divider { height:1px; background:linear-gradient(90deg,transparent,#1E3A5F,transparent); margin:24px 0; }

  .status-bar {
    border-bottom:1px solid #1E3A5F; padding:16px 32px;
    display:flex; gap:24px; font-size:13px;
    background:linear-gradient(135deg,#141B2D 0%,#0F1520 100%);
    box-shadow:0 2px 8px rgba(0,0,0,0.2);
  }
  .status-item { color:#94A9C9; }
  .status-item strong { color:#F0F4F8; font-weight:600; margin-left:6px; }

  .label {
    font-size:11px; color:#94A9C9; text-transform:uppercase;
    letter-spacing:0.5px; font-weight:500; margin-bottom:8px; display:block;
  }

  .alert {
    padding:14px 18px; border-radius:10px; font-size:13px; margin-bottom:20px; border:1px solid;
  }
  .alert-success { border-color:#00E0C6; background:rgba(0,224,198,0.1); color:#00E0C6; }
  .alert-error   { border-color:#FF6B6B; background:rgba(255,107,107,0.1); color:#FF6B6B; }
  
  .version-tag {
    font-size: 10px;
    color: #94A9C9;
    background: rgba(30, 58, 95, 0.5);
    padding: 2px 6px;
    border-radius: 4px;
    margin-left: 8px;
    vertical-align: middle;
  }
  
  a { color: #4A9EFF; text-decoration: none; }
  a:hover { text-decoration: underline; }
`;

let toastId = 0;

// ── Main App ───────────────────────────────────────────────────────────────
export default function App() {
  const [view, setView] = useState<"boot" | "auth" | "dashboard" | "error">("boot");
  const [did, setDid] = useState<string | null>(null);
  const [tab, setTab] = useState<"docs" | "create" | "sync" | "identity">("docs");
  const [docs, setDocs] = useState<Doc[]>([]);
  const [syncStatus, setSyncStatus] = useState<SyncStatus>({ pending: 0, synced: 0, failed: 0, total: 0 });
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [isOnline, setIsOnline] = useState(navigator.onLine);

  // Auth state
  const [authMode, setAuthMode] = useState<"register" | "login" | "forgot">("register");
  const [regStep, setRegStep] = useState<1 | 2 | 3>(1);
  const [captcha, setCaptcha] = useState<{ token: string; answer: string } | null>(null);
  const [regForm, setRegForm] = useState({ username: "", email: "", password: "", confirm: "", code: "" });
  const [regMsg, setRegMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [regLoading, setRegLoading] = useState(false);
  const [regUserId, setRegUserId] = useState<string | null>(null);

  const [loginForm, setLoginForm] = useState({ identifier: "", password: "" });
  const [loginMsg, setLoginMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [loginLoading, setLoginLoading] = useState(false);

  // Reset Password State
  const [resetStep, setResetStep] = useState<1 | 2>(1);
  const [resetEmail, setResetEmail] = useState("");
  const [resetForm, setResetForm] = useState({ userId: "", token: "", password: "", confirm: "" });
  const [resetMsg, setResetMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);

  const [newDoc, setNewDoc] = useState({ filename: "", content: "", tags: "" });
  const [editingDoc, setEditingDoc] = useState<Doc | null>(null);
  const [localPath, setLocalPath] = useState<string | null>(null);

  const addToast = (msg: string, type: Toast["type"] = "info") => {
    const id = toastId++;
    setToasts(t => [...t, { id, msg, type }]);
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), 4000);
  };

  useEffect(() => {
    const up   = () => { setIsOnline(true);  addToast("🟢 Connected", "success"); };
    const down = () => { setIsOnline(false); addToast("🔴 Offline",   "error"); };
    window.addEventListener("online",  up);
    window.addEventListener("offline", down);
    return () => { window.removeEventListener("online", up); window.removeEventListener("offline", down); };
  }, []);
  
  useEffect(() => {
    if (typeof window !== 'undefined' && (window as any).__TAURI__) {
      listen<{ id: string; status: string }>("sync-status", (event) => {
        const { id, status } = event.payload;
        setDocs((prevDocs) =>
          prevDocs.map((d) =>
            d.id === id ? { ...d, status: status, is_synced: status === "synced" ? 1 : 0 } : d
          )
        );
        loadSyncStatus();
      });
    }
  }, []);

  useEffect(() => {
    const init = async () => {
      await new Promise(r => setTimeout(r, 1800));
      try {
        const storedDid = await invoke<string | null>("get_stored_did");
        if (storedDid) {
          setDid(storedDid);
          setView("dashboard");
          loadDocs();
          loadSyncStatus();
        } else {
          setView("auth");
        }
      } catch (err) {
        console.error(err);
        setView("error");
      }
    };
    init();
  }, []);

  useEffect(() => {
    if (view === "dashboard") {
      const interval = setInterval(() => { loadDocs(); loadSyncStatus(); }, 5000);
      return () => clearInterval(interval);
    }
  }, [view]);

  const loadDocs = async () => {
    try { setDocs(await invoke<Doc[]>("list_documents")); }
    catch (err) { console.error("Load docs:", err); }
  };

  const loadSyncStatus = async () => {
    try { setSyncStatus(await invoke<SyncStatus>("get_sync_status")); }
    catch (err) { console.error("Sync status:", err); }
  };

  const syncNow = async () => {
    try {
      addToast("🔄 Syncing...", "info");
      const result = await invoke<string>("sync_now");
      addToast(`✅ ${result}`, "success");
      await loadDocs();
      await loadSyncStatus();
    } catch (err) {
      addToast(`❌ ${err}`, "error");
    }
  };

  const handleLogout = async () => {
    const ok = await confirm("Sign out and clear local data?", { title: "Confirm Logout", okLabel: "Logout", cancelLabel: "Cancel" });
    if (!ok) return;
    try {
      await invoke("logout");
      setDid(null);
      setDocs([]);
      setSyncStatus({ pending: 0, synced: 0, failed: 0, total: 0 });
      setView("auth");
      setAuthMode("login");
      setRegStep(1);
      setRegForm({ username: "", email: "", password: "", confirm: "", code: "" });
      setLoginForm({ identifier: "", password: "" });
      addToast("✅ Signed out", "success");
    } catch (err) {
      addToast(`❌ Logout failed: ${err}`, "error");
    }
  };

  const delDoc = async (id: string) => {
    const ok = await confirm("Delete this document permanently?", { title: "Confirm Delete", okLabel: "Delete", cancelLabel: "Cancel" });
    if (!ok) return;
    try {
      await invoke("delete_document", { id });
      addToast("✅ Document deleted", "success");
      loadDocs(); loadSyncStatus();
    } catch (err) {
      addToast(`❌ ${err}`, "error");
    }
  };

  const createDoc = async () => {
    if (!newDoc.filename.trim() || !newDoc.content.trim()) {
      addToast("❌ Filename and content are required", "error"); return;
    }
    try {
      await invoke("create_document", {
        filename: newDoc.filename,
        textContent: newDoc.content,
        tags: newDoc.tags.split(",").map(t => t.trim()).filter(Boolean),
      });
      addToast("✅ Document created", "success");
      setNewDoc({ filename: "", content: "", tags: "" });
      loadDocs(); loadSyncStatus();
      setTab("docs");
    } catch (err) {
      addToast(`❌ ${err}`, "error");
    }
  };

  const updateDoc = async () => {
    if (!editingDoc || !editingDoc.text_content.trim()) {
      addToast("❌ Content cannot be empty", "error");
      return;
    }
    try {
      await invoke("update_document", {
        id: editingDoc.id,
        textContent: editingDoc.text_content,
      });
      addToast("✅ Document updated & syncing...", "success");
      setEditingDoc(null);
      loadDocs();
      loadSyncStatus();
      setTab("docs");
    } catch (err) {
      addToast(`❌ ${err}`, "error");
    }
  };

  const handleFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = async () => {
      try {
        const arrayBuffer = reader.result as ArrayBuffer;
        const base64 = btoa(
          new Uint8Array(arrayBuffer).reduce(
            (data, byte) => data + String.fromCharCode(byte), 
            ''
          )
        );

        await invoke("upload_file", {
            filename: file.name,
            contentType: file.type || "application/octet-stream",
            fileDataB64: base64,
        });
        
        addToast(`✅ ${file.name} uploaded!`, "success");
        loadDocs();
        setTab("docs");
      } catch (err) {
        addToast(`❌ Upload failed: ${err}`, "error");
      }
    };
    reader.readAsArrayBuffer(file);
    e.target.value = '';
  };

  const handleBinaryEdit = async () => {
    if (!editingDoc) return;
    try {
      const path = await invoke<string>("open_file_for_edit", {
        id: editingDoc.id,
        filename: editingDoc.filename
      });
      setLocalPath(path);
      addToast(`📂 File opened! Edit and SAVE it in the external app, then come back and click "Upload Update".`, "info");
    } catch (err) {
      addToast(`Error: ${err}`, "error");
    }
  };

  const handleBinarySave = async () => {
    if (!editingDoc || !localPath) return;
    try {
      const result = await invoke<string>("save_edited_file", {
        id: editingDoc.id,
        localPath: localPath,
        currentVersion: editingDoc.version
      });

      if (result === "NO_CHANGES") {
        addToast("⚠️ No changes detected. Please SAVE the file in your editor first.", "error");
      } else {
        addToast("✅ File saved and syncing!", "success");
        setEditingDoc(null);
        setLocalPath(null);
        loadDocs();
      }
    } catch (err) {
      if (err.toString().includes("CONFLICT")) {
        addToast("⚠️ Conflict detected! A copy has been created.", "error");
        setEditingDoc(null);
        setLocalPath(null);
        loadDocs();
      } else {
        addToast(`Error: ${err}`, "error");
      }
    }
  };

  // ── Auth Logic ──

  const loadCaptcha = async () => {
    setRegLoading(true); setRegMsg(null);
    try {
      const res = await invoke<CaptchaResponse>("get_captcha");
      setCaptcha({ token: res.token, answer: res.answer_data });
      setRegStep(2);
    } catch (err) {
      setRegMsg({ text: `Failed to load captcha: ${err}`, type: "error" });
    } finally {
      setRegLoading(false);
    }
  };

  const handleRegister = async () => {
    if (!regForm.username || !regForm.email || !regForm.password) {
      setRegMsg({ text: "All fields are required", type: "error" }); return;
    }
    if (regForm.password !== regForm.confirm) {
      setRegMsg({ text: "Passwords don't match", type: "error" }); return;
    }
    if (!captcha || !regForm.code) {
      setRegMsg({ text: "Please enter the verification code", type: "error" }); return;
    }
    
    setRegLoading(true); setRegMsg(null);
    try {
      const result = await invoke<RegisterResponse>("register_account", {
        nickname: regForm.username,
        email: regForm.email,
        password: regForm.password,
        captchaToken: captcha.token,
        captchaSolution: regForm.code,
      });
      
      if (result.success && result.user_id) {
        setRegUserId(result.user_id);
        setRegMsg({ text: result.message, type: "success" });
        setRegStep(3); // Move to OTP Verification Step
      } else {
        setRegMsg({ text: "Registration failed.", type: "error" });
      }
    } catch (err) {
      setRegMsg({ text: `${err}`, type: "error" });
    } finally {
      setRegLoading(false);
    }
  };

  const handleVerifyEmail = async () => {
    if (!regUserId || !regForm.code) return;
    setRegLoading(true);
    try {
      const res = await invoke<GenericResponse>("verify_email", { userId: regUserId, code: regForm.code });
      addToast(res.message, "success");
      // Move to Login
      setAuthMode("login");
      setRegStep(1);
      setRegForm({ username: "", email: "", password: "", confirm: "", code: "" });
    } catch (err) {
      addToast(`${err}`, "error");
    } finally {
      setRegLoading(false);
    }
  };

  const handleResendOtp = async () => {
    if (!regUserId) return;
    try {
      const res = await invoke<GenericResponse>("resend_otp", { userId: regUserId });
      addToast(res.message, "info");
    } catch (err) {
      addToast(`${err}`, "error");
    }
  };

  const handleLogin = async () => {
    if (!loginForm.identifier || !loginForm.password) return;
    setLoginLoading(true); setLoginMsg(null);
    try {
      const result = await invoke<LoginResponse>("login", {
        identifier: loginForm.identifier,
        password: loginForm.password,
      });
      if (result.success && result.did) {
        setDid(result.did);
        setView("dashboard");
        loadDocs();
        loadSyncStatus();
        addToast("✅ Welcome back!", "success");
      } else {
        setLoginMsg({ text: "Invalid credentials.", type: "error" });
      }
    } catch (err) {
      setLoginMsg({ text: `${err}`, type: "error" });
    } finally {
      setLoginLoading(false);
    }
  };

  const handleForgotPassword = async () => {
    if(!resetEmail) return;
    setRegLoading(true); setResetMsg(null);
    try {
      const res = await invoke<GenericResponse>("forgot_password", { email: resetEmail });
      setResetMsg({ text: res.message, type: "success" });
      setResetStep(2); // Move to step 2 (enter code)
    } catch (err) {
      setResetMsg({ text: `${err}`, type: "error" });
    } finally {
      setRegLoading(false);
    }
  };

  const handleResetPassword = async () => {
    if(!resetForm.token || !resetForm.password) return;
    setRegLoading(true); setResetMsg(null);
    try {
      const res = await invoke<GenericResponse>("reset_password", {
        userId: resetForm.userId,
        token: resetForm.token,
        password: resetForm.password,
        confirm: resetForm.confirm
      });
      addToast(res.message, "success");
      setResetStep(1);
      setAuthMode("login");
    } catch (err) {
      setResetMsg({ text: `${err}`, type: "error" });
    } finally {
      setRegLoading(false);
    }
  };

  const pending = docs.filter(d => d.is_synced === 0 && d.status !== "failed");
  const failed  = docs.filter(d => d.status === "failed");

  // ── Render ───────────────────────────────────────────────────────────────

  if (view === "boot") return (
    <>
      <style>{css}</style>
      <div className="fullscreen">
        <div style={{ textAlign: "center" }}>
          <div className="boot-logo">ALEM</div>
          <div className="boot-steps">
            <div>⊙ Initializing storage...</div>
            <div>⊙ Loading identity...</div>
            <div>⊙ Checking sync status...</div>
          </div>
        </div>
      </div>
    </>
  );

  if (view === "error") return (
    <>
      <style>{css}</style>
      <div className="fullscreen">
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 56, marginBottom: 20 }}>⚠</div>
          <div style={{ fontSize: 28, marginBottom: 16, fontWeight: 600 }}>System Error</div>
          <div style={{ marginBottom: 32, color: "#94A9C9" }}>Failed to initialize application</div>
          <button className="btn" onClick={() => window.location.reload()}>↺ Retry</button>
        </div>
      </div>
    </>
  );

  if (view === "auth") return (
    <>
      <style>{css}</style>
      <div className="fullscreen">
        <div className="auth-container">
          <div className="auth-title">ALEM</div>

          {/* Reset Password Flow (Step 2) */}
          {resetStep === 2 ? (
            <div>
              <h3 style={{marginBottom: 20, color: "#F0F4F8"}}>Reset Password</h3>
              {resetMsg && <div className={`alert alert-${resetMsg.type}`}>{resetMsg.text}</div>}
              
              <p style={{marginBottom: 20, color: "#94A9C9"}}>
                Enter the code from your email and your new password.
              </p>
              
              <input className="input" placeholder="User ID (from email link)" value={resetForm.userId} onChange={e => setResetForm({...resetForm, userId: e.target.value})} />
              <input className="input" placeholder="Reset Token" value={resetForm.token} onChange={e => setResetForm({...resetForm, token: e.target.value})} />
              <input className="input" type="password" placeholder="New Password" value={resetForm.password} onChange={e => setResetForm({...resetForm, password: e.target.value})} />
              <input className="input" type="password" placeholder="Confirm Password" value={resetForm.confirm} onChange={e => setResetForm({...resetForm, confirm: e.target.value})} />
              
              <button className="btn" onClick={handleResetPassword} disabled={regLoading} style={{width: "100%"}}>
                {regLoading ? "⊙ Resetting..." : "✦ Reset Password"}
              </button>
              <button className="btn btn-secondary" onClick={() => { setResetStep(1); setAuthMode("login"); }} style={{width: "100%", marginTop: 10}}>
                ← Back to Login
              </button>
            </div>
          ) : (
            <>
              {/* Auth Tabs */}
              <div className="auth-tabs">
                <button className={`auth-tab ${authMode === "register" ? "active" : ""}`} onClick={() => { setAuthMode("register"); setRegMsg(null); setLoginMsg(null); setRegStep(1); }}>✦ Create Account</button>
                <button className={`auth-tab ${authMode === "login" ? "active" : ""}`} onClick={() => { setAuthMode("login"); setRegMsg(null); setLoginMsg(null); }}>⊙ Sign In</button>
              </div>

              {/* REGISTER FLOW */}
              {authMode === "register" && (
                <div>
                  {regMsg && <div className={`alert alert-${regMsg.type}`}>{regMsg.text}</div>}
                  
                  {/* Step 1: Start */}
                  {regStep === 1 && (
                    <div>
                      <p style={{ marginBottom: 32, color: "#94A9C9", fontSize: 14, lineHeight: 1.7 }}>
                        Create a secure decentralized identity.
                      </p>
                      <button className="btn" onClick={loadCaptcha} disabled={regLoading} style={{ width: "100%" }}>
                        {regLoading ? "⊙ Loading..." : "✦ Begin Registration"}
                      </button>
                    </div>
                  )}
                  
                  {/* Step 2: Form & Captcha */}
                  {regStep === 2 && (
                    <div>
                      {captcha && (
                        <div className="captcha-box">
                          <div className="captcha-label">Verification Code</div>
                          <div className="captcha-code">{captcha.answer}</div>
                        </div>
                      )}
                      <input className="input" placeholder="Username" value={regForm.username} onChange={e => setRegForm({ ...regForm, username: e.target.value })} />
                      <input className="input" placeholder="Email" type="email" value={regForm.email} onChange={e => setRegForm({ ...regForm, email: e.target.value })} />
                      <input className="input" placeholder="Password" type="password" value={regForm.password} onChange={e => setRegForm({ ...regForm, password: e.target.value })} />
                      <input className="input" placeholder="Confirm Password" type="password" value={regForm.confirm} onChange={e => setRegForm({ ...regForm, confirm: e.target.value })} />
                      <input className="input" placeholder="Enter Verification Code" value={regForm.code} onChange={e => setRegForm({ ...regForm, code: e.target.value })} />
                      <div className="btn-group">
                        <button className="btn" onClick={handleRegister} disabled={regLoading}>{regLoading ? "⊙ Creating..." : "✦ Create Account"}</button>
                        <button className="btn btn-secondary" onClick={loadCaptcha} disabled={regLoading}>↺ New Code</button>
                      </div>
                    </div>
                  )}

                  {/* Step 3: Verify OTP */}
                  {regStep === 3 && (
                    <div>
                      <h3 style={{marginBottom: 20, color: "#F0F4F8"}}>Verify Email</h3>
                      <p style={{color: "#94A9C9", marginBottom: 20}}>
                        Enter the 6-digit code sent to your email.
                      </p>
                      
                      <input className="input" placeholder="6-Digit Code" value={regForm.code} onChange={e => setRegForm({ ...regForm, code: e.target.value })} />
                      
                      <button className="btn" onClick={handleVerifyEmail} disabled={regLoading} style={{width: "100%"}}>
                        {regLoading ? "⊙ Verifying..." : "✦ Verify Email"}
                      </button>
                      <button className="btn btn-secondary" onClick={handleResendOtp} style={{width: "100%", marginTop: 10}}>
                        Resend Code
                      </button>
                    </div>
                  )}
                </div>
              )}

              {/* LOGIN FLOW */}
              {authMode === "login" && (
                <div>
                  {loginMsg && <div className={`alert alert-${loginMsg.type}`}>{loginMsg.text}</div>}
                  <input className="input" placeholder="Username" value={loginForm.identifier} onChange={e => setLoginForm({ ...loginForm, identifier: e.target.value })} />
                  <input className="input" placeholder="Password" type="password" value={loginForm.password} onChange={e => setLoginForm({ ...loginForm, password: e.target.value })} />
                  <button className="btn" onClick={handleLogin} disabled={loginLoading} style={{ width: "100%" }}>
                    {loginLoading ? "⊙ Signing in..." : "⊙ Sign In"}
                  </button>
                  
                  <div style={{textAlign: "center", marginTop: 20}}>
                    <a href="#" onClick={(e) => { e.preventDefault(); setAuthMode("forgot"); setResetMsg(null); }} style={{color: "#4A9EFF", fontSize: 13}}>
                      Forgot Password?
                    </a>
                  </div>
                </div>
              )}

              {/* FORGOT PASSWORD FLOW */}
              {authMode === "forgot" && (
                <div>
                  <h3 style={{marginBottom: 20, color: "#F0F4F8"}}>Forgot Password</h3>
                  {resetMsg && <div className={`alert alert-${resetMsg.type}`}>{resetMsg.text}</div>}
                  <p style={{color: "#94A9C9", marginBottom: 20}}>
                    Enter your email to receive a reset link.
                  </p>
                  <input className="input" placeholder="Email" value={resetEmail} onChange={e => setResetEmail(e.target.value)} />
                  <button className="btn" onClick={handleForgotPassword} disabled={regLoading} style={{width: "100%"}}>
                    {regLoading ? "⊙ Sending..." : "Send Reset Link"}
                  </button>
                  <button className="btn btn-secondary" onClick={() => setAuthMode("login")} style={{width: "100%", marginTop: 10}}>
                    ← Back to Login
                  </button>
                </div>
              )}
            </>
          )}
        </div>
      </div>
      <div className="toast-container">{toasts.map(t => <div key={t.id} className={`toast ${t.type}`}>{t.msg}</div>)}</div>
    </>
  );

  // ── Dashboard ──────────────────────────────────────────────────────────
  return (
    <>
      <style>{css}</style>
      <div className="app">
        <header className="header">
          <div className="logo">ALEM</div>
          <div className="header-right">
            <div><span className={`sync-dot ${isOnline ? "online" : "offline"}`} />{isOnline ? "CONNECTED" : "OFFLINE"}</div>
            <div style={{ maxWidth: 180, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", fontFamily: "'JetBrains Mono',monospace", fontSize: 11 }}>{did}</div>
            <button className="btn btn-danger" onClick={handleLogout} style={{ padding: "6px 16px", fontSize: 12 }}>Logout</button>
          </div>
        </header>

        <nav className="sidebar">
          {[
            { id: "docs" as const, label: "◉ Documents", badge: null },
            { id: "create" as const, label: "⊕ New Document", badge: null },
            { id: "sync" as const, label: "⟲ Sync", badge: pending.length || null },
            { id: "identity" as const, label: "⬢ Identity", badge: null },
          ].map(n => (
            <div key={n.id} className={`nav-item ${tab === n.id ? "active" : ""}`} onClick={() => { setTab(n.id); setEditingDoc(null); setLocalPath(null); }}>
              <span>{n.label}</span>
              {n.badge != null && <span className="badge">{n.badge}</span>}
            </div>
          ))}
        </nav>

        <main className="main">
          <div className="status-bar">
            <div className="status-item">Total<strong>{syncStatus.total}</strong></div>
            <div className="status-item">Synced<strong style={{ color: "#00E0C6" }}>{syncStatus.synced}</strong></div>
            <div className="status-item">Pending<strong style={{ color: "#FFB800" }}>{syncStatus.pending}</strong></div>
            <div className="status-item">Failed<strong style={{ color: "#FF6B6B" }}>{syncStatus.failed}</strong></div>
          </div>

          <div className="panel">
            {/* Documents Tab */}
            {tab === "docs" && (
              <>
                {editingDoc ? (
                  <>
                    <div className="panel-title">Editing: {editingDoc.filename}</div>
                    <div className="panel-sub">
                        Type: <strong>{editingDoc.content_type || 'text/plain'}</strong>
                        <span className="version-tag">v{editingDoc.version}</span>
                        {editingDoc.conflict_copy_of && <span className="doc-conflict">(CONFLICT COPY)</span>}
                    </div>
                    
                    {(!editingDoc.content_type || editingDoc.content_type === "text/plain") ? (
                        <div className="card">
                            <textarea 
                            className="input" 
                            rows={12}
                            value={editingDoc.text_content}
                            onChange={(e) => setEditingDoc({ ...editingDoc, text_content: e.target.value })}
                            placeholder="Document content..."
                            />
                            <div style={{ display: "flex", gap: "12px", marginTop: "16px" }}>
                            <button className="btn" onClick={updateDoc} style={{ flex: 1 }}>💾 Save Changes</button>
                            <button className="btn btn-secondary" onClick={() => setEditingDoc(null)} style={{ flex: 1 }}>✖ Cancel</button>
                            </div>
                        </div>
                    ) : (
                        <div className="card">
                            <div style={{ textAlign: "center", padding: "20px 0" }}>
                                <div style={{ fontSize: "32px", marginBottom: "10px" }}>📁</div>
                                <h3 style={{ marginBottom: "10px" }}>{editingDoc.filename}</h3>
                                <p style={{color: "#94A9C9", marginBottom: "20px", fontSize: "13px"}}>
                                    External editing mode (Version {editingDoc.version})
                                </p>
                                
                                {!localPath && (
                                  <div style={{ background: "rgba(255, 184, 0, 0.1)", border: "1px solid #FFB800", padding: "15px", borderRadius: "8px", marginBottom: "20px", color: "#FFB800" }}>
                                    Click <strong>"Open File"</strong> to start editing.
                                  </div>
                                )}

                                {localPath && (
                                  <div style={{ background: "rgba(0, 224, 198, 0.1)", border: "1px solid #00E0C6", padding: "15px", borderRadius: "8px", marginBottom: "20px", color: "#00E0C6" }}>
                                    ✅ File opened externally.<br/>
                                    <strong>1.</strong> Edit the file in your other app.<br/>
                                    <strong>2.</strong> <strong>SAVE</strong> the file in that app.<br/>
                                    <strong>3.</strong> Click <strong>"Upload Update"</strong> below.
                                  </div>
                                )}

                                <div style={{ display: 'flex', gap: '12px', justifyContent: 'center' }}>
                                    <button className="btn" onClick={handleBinaryEdit}>
                                        📂 Open File
                                    </button>
                                    
                                    <button 
                                        className="btn btn-success" 
                                        onClick={handleBinarySave}
                                        disabled={!localPath} 
                                    >
                                        ⬆️ Upload Update
                                    </button>
                                    
                                    <button 
                                        className="btn btn-secondary" 
                                        onClick={() => setEditingDoc(null)}
                                    >
                                        ✖ Cancel
                                    </button>
                                </div>
                                {localPath && <p style={{fontSize: "11px", color: "#666", marginTop: "15px"}}>Local cache: {localPath}</p>}
                            </div>
                        </div>
                    )}
                  </>
                ) : (
                  <>
                    <div className="panel-title">Documents</div>
                    <div className="panel-sub">{docs.length} total · {syncStatus.synced} synced to cloud</div>
                    {docs.length === 0 ? (
                      <div className="empty">
                        <div className="empty-icon">◉</div>
                        <div style={{ fontSize: 16, marginBottom: 8 }}>No documents yet</div>
                        <div style={{ fontSize: 13 }}>Create your first document to get started</div>
                      </div>
                    ) : (
                      <div className="doc-list">
                        {docs.map(d => (
                          <div key={d.id} className="doc-item">
                            <div className="doc-info">
                              <div className="doc-name">
                                {d.filename}
                                {d.conflict_copy_of && <span className="doc-conflict">(Conflict Copy)</span>}
                              </div>
                              <div className="doc-meta">
                                {new Date(d.created_at).toLocaleString()} · {d.content_type || 'text/plain'}
                              </div>
                            </div>
                            <div className="doc-status">
                              <span className={`tag ${d.is_synced === 1 ? "tag-synced" : d.status === "failed" ? "tag-failed" : "tag-pending"}`}>
                                {d.is_synced === 1 ? "synced" : d.status}
                              </span>
                              <span className="version-tag">v{d.version}</span>
                              
                              <button className="btn" onClick={() => setEditingDoc(d)} style={{ padding: "6px 14px", fontSize: 12 }}>Edit</button>
                              
                              <button className="btn btn-danger" onClick={() => delDoc(d.id)} style={{ padding: "6px 14px", fontSize: 12 }}>Delete</button>
                            </div>
                          </div>
                        ))}
                      </div>
                    )}
                  </>
                )}
              </>
            )}

            {/* Create Tab */}
            {tab === "create" && (
              <>
                <div className="panel-title">New Document</div>
                <div className="panel-sub">Create a local document · Automatically syncs when online</div>
                
                {/* Binary Upload */}
                <div className="card" style={{ marginBottom: "20px", borderStyle: "dashed" }}>
                  <div style={{ textAlign: "center", padding: "20px 0" }}>
                    <div style={{ fontSize: "32px", marginBottom: "10px" }}>📁</div>
                    <div style={{ fontWeight: 600, marginBottom: "10px" }}>Upload Any File</div>
                    <div style={{ fontSize: "12px", color: "#94A9C9", marginBottom: "20px" }}>
                      Supports: PDF, Images, Videos, MP3, ZIP, etc.
                    </div>
                    
                    <input 
                      type="file" 
                      id="file-upload" 
                      style={{ display: 'none' }} 
                      onChange={handleFileUpload}
                    />
                    <button 
                      className="btn btn-success" 
                      onClick={() => document.getElementById('file-upload')?.click()}
                    >
                      ⬆️ Select File to Upload
                    </button>
                  </div>
                </div>

                {/* Text Create */}
                <div className="card">
                  <div style={{ fontSize: "14px", fontWeight: 600, marginBottom: "16px", color: "#94A9C9" }}>
                    OR CREATE TEXT DOCUMENT
                  </div>
                  <input className="input" placeholder="Filename (e.g., project-notes.txt)" value={newDoc.filename} onChange={e => setNewDoc({ ...newDoc, filename: e.target.value })} />
                  <textarea className="input" placeholder="Document content..." rows={8} value={newDoc.content} onChange={e => setNewDoc({ ...newDoc, content: e.target.value })} />
                  <input className="input" placeholder="Tags (comma separated)" value={newDoc.tags} onChange={e => setNewDoc({ ...newDoc, tags: e.target.value })} />
                  <button className="btn" onClick={createDoc} style={{ width: "100%" }}>⊕ Create Text Document</button>
                </div>
              </>
            )}

            {/* Sync Tab */}
            {tab === "sync" && (
              <>
                <div className="panel-title">Sync Engine</div>
                <div className="panel-sub">Background synchronization · Offline queue · Auto-retry on failure</div>
                <div className="card">
                  <div style={{ marginBottom: 20, display: "flex", alignItems: "center", gap: 12 }}>
                    <div className={`sync-dot ${isOnline ? "online" : "offline"}`} />
                    <span style={{ fontWeight: 600 }}>{isOnline ? "Connected to server" : "Offline mode"}</span>
                  </div>
                  <button className="btn" onClick={syncNow} disabled={!isOnline || syncStatus.pending === 0} style={{ width: "100%" }}>
                    {isOnline ? (syncStatus.pending > 0 ? `⟲ Sync ${syncStatus.pending} Document(s)` : "✓ Everything Synced") : "⚠ Offline — Waiting for connection"}
                  </button>
                </div>

                {pending.length > 0 && (
                  <div style={{ border: "1px solid #FFB800", padding: 20, background: "rgba(255,184,0,0.1)", marginBottom: 20, borderRadius: 12 }}>
                    <div style={{ fontWeight: 600, marginBottom: 12, color: "#FFB800" }}>⏳ Pending Upload</div>
                    {pending.map(d => <div key={d.id} style={{ fontSize: 13, marginBottom: 4, fontFamily: "'JetBrains Mono',monospace" }}>• {d.filename}</div>)}
                  </div>
                )}

                {failed.length > 0 && (
                  <div style={{ border: "1px solid #FF6B6B", padding: 20, background: "rgba(255,107,107,0.1)", borderRadius: 12 }}>
                    <div style={{ fontWeight: 600, marginBottom: 12, color: "#FF6B6B" }}>✗ Failed Uploads</div>
                    {failed.map(d => <div key={d.id} style={{ fontSize: 13, marginBottom: 4, color: "#FF6B6B", fontFamily: "'JetBrains Mono',monospace" }}>• {d.filename}</div>)}
                    <button className="btn btn-danger" onClick={syncNow} style={{ marginTop: 16 }}>↺ Retry Failed</button>
                  </div>
                )}
              </>
            )}

            {/* Identity Tab */}
            {tab === "identity" && (
              <>
                <div className="panel-title">Identity</div>
                <div className="panel-sub">Decentralized identifier · Cryptographically verified</div>
                <div className="card">
                  <span className="label">Your DID</span>
                  <div className="did-box">{did}</div>
                  <div className="divider" />
                  <div style={{ fontSize: 13, color: "#94A9C9", lineHeight: 2 }}>
                    <div><strong style={{ color: "#F0F4F8" }}>Method:</strong> did:przma</div>
                    <div><strong style={{ color: "#F0F4F8" }}>Format:</strong> Base64URL SHA-256</div>
                    <div><strong style={{ color: "#F0F4F8" }}>Type:</strong>   Decentralized Identifier</div>
                    <div><strong style={{ color: "#F0F4F8" }}>Status:</strong> Active</div>
                  </div>
                </div>
              </>
            )}
          </div>
        </main>
      </div>
      <div className="toast-container">{toasts.map(t => <div key={t.id} className={`toast ${t.type}`}>{t.msg}</div>)}</div>
    </>
  );
}