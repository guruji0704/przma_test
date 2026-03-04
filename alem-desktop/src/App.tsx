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
  did: string | null;
  message: string;
}

interface LoginResponse {
  success: boolean;
  did: string | null;
  access_token: string | null;
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

  .stats { display:grid; grid-template-columns:repeat(4,1fr); gap:16px; margin-bottom:32px; }

  .stat {
    border:1px solid #1E3A5F; padding:20px;
    background:linear-gradient(135deg,#141B2D 0%,#0F1520 100%);
    border-radius:12px; transition:all 0.3s cubic-bezier(0.4,0,0.2,1);
  }
  .stat:hover { border-color:#4A9EFF; transform:translateY(-4px); box-shadow:0 8px 24px rgba(74,158,255,0.2); }

  .stat-value {
    font-size:36px; font-weight:700; line-height:1; margin-bottom:8px;
    background:linear-gradient(135deg,#4A9EFF 0%,#FFB800 100%);
    -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;
  }
  .stat-label { font-size:11px; color:#94A9C9; text-transform:uppercase; letter-spacing:0.5px; font-weight:500; }

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

  /* ── Full-screen views ── */
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

  /* ── Auth card ── */
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

  .sync-flow { border:1px solid #1E3A5F; padding:20px; margin-top:20px; border-radius:12px; background:linear-gradient(135deg,#141B2D 0%,#0F1520 100%); }

  .sync-step {
    padding:10px 0 10px 20px; border-left:2px solid #1E3A5F; margin-bottom:10px;
    font-size:13px; color:#94A9C9; font-family:'JetBrains Mono',monospace; transition:all 0.2s;
  }
  .sync-step:hover { border-left-color:#4A9EFF; color:#F0F4F8; padding-left:24px; }

  .label {
    font-size:11px; color:#94A9C9; text-transform:uppercase;
    letter-spacing:0.5px; font-weight:500; margin-bottom:8px; display:block;
  }

  .alert {
    padding:14px 18px; border-radius:10px; font-size:13px; margin-bottom:20px; border:1px solid;
  }
  .alert-success { border-color:#00E0C6; background:rgba(0,224,198,0.1); color:#00E0C6; }
  .alert-error   { border-color:#FF6B6B; background:rgba(255,107,107,0.1); color:#FF6B6B; }
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

  // Auth mode: register or login
  const [authMode, setAuthMode] = useState<"register" | "login">("register");

  // Register state
  const [regStep, setRegStep] = useState<1 | 2 | 3>(1);
  const [captcha, setCaptcha] = useState<{ token: string; answer: string } | null>(null);
  const [regForm, setRegForm] = useState({ username: "", email: "", password: "", confirm: "", code: "" });
  const [regMsg, setRegMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [regLoading, setRegLoading] = useState(false);

  // Login state
  const [loginForm, setLoginForm] = useState({ identifier: "", password: "" });
  const [loginMsg, setLoginMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [loginLoading, setLoginLoading] = useState(false);

  // New doc
  const [newDoc, setNewDoc] = useState({ filename: "", content: "", tags: "" });
  
  // ✅ NEW: Edit State
  const [editingDoc, setEditingDoc] = useState<Doc | null>(null);

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
  
  // ✅ Listen for sync-status events from Rust
  useEffect(() => {
    if (typeof window !== 'undefined' && (window as any).__TAURI__) {
      const unlisten = listen<{ id: string; status: string }>("sync-status", (event) => {
        const { id, status } = event.payload;
        setDocs((prevDocs) =>
          prevDocs.map((d) =>
            d.id === id ? { ...d, status: status, is_synced: status === "synced" ? 1 : 0 } : d
          )
        );
        loadSyncStatus();
      });
      return () => { unlisten.then(f => f()); };
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

  // ✅ NEW: Update Document Function
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

  // ── Registration flow ──────────────────────────────────────────────────

  const loadCaptcha = async () => {
    setRegLoading(true);
    setRegMsg(null);
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
    setRegLoading(true);
    setRegMsg(null);
    try {
      const result = await invoke<RegisterResponse>("register_account", {
        nickname: regForm.username,
        email: regForm.email,
        password: regForm.password,
        captchaToken: captcha.token,
        captchaSolution: regForm.code,
      });
      if (result.success) {
        setRegStep(3);
        setRegMsg({ text: result.message || "Account created! Please sign in.", type: "success" });
        const savedUsername = regForm.username;
        const savedPassword = regForm.password;
        setTimeout(() => {
          setAuthMode("login");
          setLoginForm({ identifier: savedUsername, password: savedPassword });
          setRegStep(1);
          setRegForm({ username: "", email: "", password: "", confirm: "", code: "" });
          setCaptcha(null);
          setRegMsg(null);
        }, 2000);
      } else {
        setRegMsg({ text: "Registration failed. Please try again.", type: "error" });
        setRegStep(1);
      }
    } catch (err) {
      setRegMsg({ text: `Registration failed: ${err}`, type: "error" });
      setRegStep(1);
    } finally {
      setRegLoading(false);
    }
  };

  // ── Login flow ─────────────────────────────────────────────────────────

  const handleLogin = async () => {
    if (!loginForm.identifier || !loginForm.password) {
      setLoginMsg({ text: "Email/username and password are required", type: "error" }); return;
    }
    setLoginLoading(true);
    setLoginMsg(null);
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
        setLoginMsg({ text: "Invalid credentials. Please try again.", type: "error" });
      }
    } catch (err) {
      setLoginMsg({ text: `Login failed: ${err}`, type: "error" });
    } finally {
      setLoginLoading(false);
    }
  };

  const pending = docs.filter(d => d.is_synced === 0 && d.status !== "failed");
  const failed  = docs.filter(d => d.status === "failed");

  // ── Boot ──────────────────────────────────────────────────────────────
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

  // ── Error ─────────────────────────────────────────────────────────────
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

  // ── Auth (Register / Login) ────────────────────────────────────────────
  if (view === "auth") return (
    <>
      <style>{css}</style>
      <div className="fullscreen">
        <div className="auth-container">
          <div className="auth-title">ALEM</div>

          <div className="auth-tabs">
            <button
              className={`auth-tab ${authMode === "register" ? "active" : ""}`}
              onClick={() => { setAuthMode("register"); setRegMsg(null); setLoginMsg(null); }}
            >
              ✦ Create Account
            </button>
            <button
              className={`auth-tab ${authMode === "login" ? "active" : ""}`}
              onClick={() => { setAuthMode("login"); setRegMsg(null); setLoginMsg(null); }}
            >
              ⊙ Sign In
            </button>
          </div>

          {authMode === "register" && (
            <div>
              {regMsg && <div className={`alert alert-${regMsg.type}`}>{regMsg.text}</div>}
              {regStep === 1 && (
                <div>
                  <p style={{ marginBottom: 32, color: "#94A9C9", fontSize: 14, lineHeight: 1.7 }}>
                    Create your account to receive a decentralized identifier and start syncing documents securely.
                  </p>
                  <button className="btn" onClick={loadCaptcha} disabled={regLoading} style={{ width: "100%" }}>
                    {regLoading ? "⊙ Loading..." : "✦ Begin Registration"}
                  </button>
                </div>
              )}
              {regStep === 2 && (
                <div>
                  {captcha && (
                    <div className="captcha-box">
                      <div className="captcha-label">Verification Code</div>
                      <div className="captcha-code">{captcha.answer}</div>
                    </div>
                  )}
                  <input className="input" placeholder="Username" value={regForm.username} onChange={e => setRegForm({ ...regForm, username: e.target.value })} disabled={regLoading} />
                  <input className="input" placeholder="Email" type="email" value={regForm.email} onChange={e => setRegForm({ ...regForm, email: e.target.value })} disabled={regLoading} />
                  <input className="input" placeholder="Password" type="password" value={regForm.password} onChange={e => setRegForm({ ...regForm, password: e.target.value })} disabled={regLoading} />
                  <input className="input" placeholder="Confirm Password" type="password" value={regForm.confirm} onChange={e => setRegForm({ ...regForm, confirm: e.target.value })} disabled={regLoading} />
                  <input className="input" placeholder="Enter Verification Code" value={regForm.code} onChange={e => setRegForm({ ...regForm, code: e.target.value })} disabled={regLoading} />
                  <div className="btn-group">
                    <button className="btn" onClick={handleRegister} disabled={regLoading}>{regLoading ? "⊙ Creating..." : "✦ Create Account"}</button>
                    <button className="btn btn-secondary" onClick={loadCaptcha} disabled={regLoading}>↺ New Code</button>
                  </div>
                </div>
              )}
              {regStep === 3 && (
                <div style={{ textAlign: "center" }}>
                  <div style={{ fontSize: 28, marginBottom: 16, fontWeight: 600, color: "#00E0C6" }}>✓ Registration Complete</div>
                  <div style={{ color: "#94A9C9" }}>Redirecting to sign in...</div>
                </div>
              )}
            </div>
          )}

          {authMode === "login" && (
            <div>
              {loginMsg && <div className={`alert alert-${loginMsg.type}`}>{loginMsg.text}</div>}
              <input className="input" placeholder="Username (nickname)" value={loginForm.identifier} onChange={e => setLoginForm({ ...loginForm, identifier: e.target.value })} disabled={loginLoading} />
              <input className="input" placeholder="Password" type="password" value={loginForm.password} onChange={e => setLoginForm({ ...loginForm, password: e.target.value })} disabled={loginLoading} onKeyDown={e => e.key === "Enter" && handleLogin()} />
              <div style={{ fontSize: 11, color: "#94A9C9", marginBottom: 16, marginTop: -8, fontFamily: "'JetBrains Mono', monospace" }}>
                ⓘ Use your <strong style={{ color: "#4A9EFF" }}>username</strong>, not your email address
              </div>
              <button className="btn" onClick={handleLogin} disabled={loginLoading} style={{ width: "100%" }}>{loginLoading ? "⊙ Signing in..." : "⊙ Sign In"}</button>
            </div>
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
            <div key={n.id} className={`nav-item ${tab === n.id ? "active" : ""}`} onClick={() => { setTab(n.id); setEditingDoc(null); }}>
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
            {/* ── Documents tab ── */}
            {tab === "docs" && (
              <>
                {/* ✅ Edit Mode */}
                {editingDoc ? (
                  <>
                    <div className="panel-title">Editing: {editingDoc.filename}</div>
                    <div className="panel-sub">Modify content below. Changes will sync automatically.</div>
                    
                    <div className="card">
                      <div style={{ marginBottom: 16, color: "#94A9C9", fontSize: 12 }}>
                        Last Modified: {new Date(editingDoc.updated_at || editingDoc.created_at).toLocaleString()}
                      </div>
                      
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
                  </>
                ) : (
                  // List Mode
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
                              <div className="doc-name">{d.filename}</div>
                              <div className="doc-meta">{new Date(d.created_at).toLocaleString()}</div>
                            </div>
                            <div className="doc-status">
                              <span className={`tag ${d.is_synced === 1 ? "tag-synced" : d.status === "failed" ? "tag-failed" : "tag-pending"}`}>
                                {d.is_synced === 1 ? "synced" : d.status}
                              </span>
                              
                              {/* ✅ Edit Button */}
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

            {/* ── Create tab ── */}
            {tab === "create" && (
              <>
                <div className="panel-title">New Document</div>
                <div className="panel-sub">Create a local document · Automatically syncs when online</div>
                <div className="card">
                  <input className="input" placeholder="Filename (e.g., project-notes.txt)" value={newDoc.filename} onChange={e => setNewDoc({ ...newDoc, filename: e.target.value })} />
                  <textarea className="input" placeholder="Document content..." rows={12} value={newDoc.content} onChange={e => setNewDoc({ ...newDoc, content: e.target.value })} />
                  <input className="input" placeholder="Tags (comma separated)" value={newDoc.tags} onChange={e => setNewDoc({ ...newDoc, tags: e.target.value })} />
                  <button className="btn" onClick={createDoc} style={{ width: "100%" }}>⊕ Create Document</button>
                </div>
              </>
            )}

            {/* ── Sync tab ── */}
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

            {/* ── Identity tab ── */}
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