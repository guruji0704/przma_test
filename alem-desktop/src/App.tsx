import { useState, useEffect, useMemo } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { confirm } from "@tauri-apps/plugin-dialog";
import { tableFromIPC } from "apache-arrow";

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
  file_size: number;
  conflict_copy_of: string | null;
  tags?: string[];
}

interface Toast {
  id: number;
  msg: string;
  type: "info" | "success" | "error";
}

function formatFileSize(bytes: number) {
  if (!bytes || bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

// ── Doc Action Icons ───────────────────────────────────────────────────────
const IconView = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" /><circle cx="12" cy="12" r="3" /></svg>;
const IconEdit = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" /><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" /></svg>;
const IconDownload = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><polyline points="7 10 12 15 17 10" /><line x1="12" y1="15" x2="12" y2="3" /></svg>;
const IconDelete = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="3 6 5 6 21 6" /><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" /><line x1="10" y1="11" x2="10" y2="17" /><line x1="14" y1="11" x2="14" y2="17" /></svg>;

const Thumbnail = ({ type, filename, id }: { type: string, filename: string, id?: string }) => {
  const [src, setSrc] = useState<string | null>(null);
  const ct = type.toLowerCase();
  const isImage = ct.startsWith("image/");
  
  useEffect(() => {
    if (isImage && id) {
      invoke<number[]>("get_file_bytes", { id })
        .then(bytes => {
          const blob = new Blob([new Uint8Array(bytes)], { type: ct });
          setSrc(URL.createObjectURL(blob));
        })
        .catch(console.error);
    }
  }, [id, isImage, ct]);

  const isVideo = ct.startsWith("video/");
  const isAudio = ct.startsWith("audio/");
  const isPdf = ct === "application/pdf";
  const isDoc = ct.includes("word") || ct.includes("officedocument") || filename.endsWith(".docx") || filename.endsWith(".doc");

  if (isImage && src) return <img src={src} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />;

  if (isImage) return (
    <div style={{ background: 'rgba(74, 158, 255, 0.1)', width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ color: '#4A9EFF' }}><rect x="3" y="3" width="18" height="18" rx="2" ry="2" /><circle cx="8.5" cy="8.5" r="1.5" /><polyline points="21 15 16 10 5 21" /></svg>
    </div>
  );
  if (isVideo) return (
    <div style={{ background: 'rgba(255, 184, 0, 0.1)', width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ color: '#FFB800' }}><polygon points="23 7 16 12 23 17 23 7" /><rect x="1" y="5" width="15" height="14" rx="2" ry="2" /></svg>
    </div>
  );
  if (isAudio) return (
    <div style={{ background: 'rgba(0, 224, 198, 0.1)', width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ color: '#00E0C6' }}><path d="M9 18V5l12-2v13" /><circle cx="6" cy="18" r="3" /><circle cx="18" cy="16" r="3" /></svg>
    </div>
  );
  if (isPdf) return (
    <div style={{ background: 'rgba(255, 107, 107, 0.1)', width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ color: '#FF6B6B' }}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><polyline points="14 2 14 8 20 8" /><line x1="16" y1="13" x2="8" y2="13" /><line x1="16" y1="17" x2="8" y2="17" /><polyline points="10 9 9 9 8 9" /></svg>
    </div>
  );
  if (isDoc) return (
    <div style={{ background: 'rgba(74, 158, 255, 0.1)', width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ color: '#4A9EFF' }}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><polyline points="14 2 14 8 20 8" /><line x1="16" y1="13" x2="8" y2="13" /><line x1="16" y1="17" x2="8" y2="17" /><line x1="12" y1="9" x2="8" y2="9" /></svg>
    </div>
  );

  return (
    <div style={{ background: 'rgba(255, 255, 255, 0.03)', width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ opacity: 0.3 }}><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z" /><polyline points="13 2 13 9 20 9" /></svg>
    </div>
  );
};

// ── SVG Icons ──────────────────────────────────────────────────────────────
const EyeOpenIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path>
    <circle cx="12" cy="12" r="3"></circle>
  </svg>
);

const EyeClosedIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"></path>
    <line x1="1" y1="1" x2="23" y2="23"></line>
  </svg>
);

// ── Styles ─────────────────────────────────────────────────────────────────
const css = `
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=JetBrains+Mono:wght@400;500;600&display=swap');

  :root {
    --bg-primary: #05070A;
    --bg-secondary: #0A0D14;
    --bg-header: rgba(5, 7, 10, 0.8);
    --text-primary: #FFFFFF;
    --text-secondary: rgba(255,255,255,0.5);
    --border: rgba(255,255,255,0.1);
    --accent: #58A6FF;
    --accent-glow: rgba(88,166,255,0.15);
    --card-shadow: 0 8px 32px rgba(0,0,0,0.4);
  }

  [data-theme='light'] {
    --bg-primary: #FFFFFF;
    --bg-secondary: #F4F7FA;
    --bg-header: rgba(255, 255, 255, 0.9);
    --text-primary: #1E293B;
    --text-secondary: #64748B;
    --border: #E2E8F0;
    --accent: #2563EB;
    --accent-glow: rgba(37, 99, 235, 0.08);
    --card-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);
  }

  [data-theme='dark'] {
    --bg-primary: #0B0E14;
    --bg-secondary: #161B22;
    --bg-header: rgba(11, 14, 20, 0.8);
    --text-primary: #F0F6FC;
    --text-secondary: #8B949E;
    --border: #30363D;
    --accent: #58A6FF;
    --accent-glow: rgba(88, 166, 255, 0.15);
    --card-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  }

  [data-theme='prism'] body {
    background: var(--bg-primary);
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { 
    background: var(--bg-primary); 
    color: var(--text-primary); 
    font-family: 'Inter', system-ui, sans-serif;
    transition: background 0.4s ease, color 0.4s ease;
    height: 100vh;
    overflow: hidden;
  }

  .app-container {
    height: 100vh;
    display: grid;
    grid-template-columns: 240px 1fr;
    grid-template-rows: 72px 1fr;
    overflow: hidden;
    position: relative;
  }

  .header {
    grid-column: 1 / -1;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 40px;
    background: var(--bg-header);
    backdrop-filter: blur(32px);
    border-bottom: 1px solid var(--border);
    z-index: 1000;
  }

  .prism-bg {
    position: fixed;
    inset: 0;
    z-index: -1;
    overflow: hidden;
    opacity: 0;
    transition: opacity 1s ease;
    pointer-events: none;
  }
  [data-theme='prism'] .prism-bg { opacity: 1; }

  .prism-orb {
    position: absolute;
    width: 600px;
    height: 600px;
    border-radius: 50%;
    filter: blur(120px);
    mix-blend-mode: screen;
    animation: flow 20s infinite alternate;
  }

  @keyframes flow {
    0% { transform: translate(-20%, -20%) rotate(0deg); }
    100% { transform: translate(30%, 40%) rotate(360deg); }
  }

  .sidebar { 
    background: var(--bg-secondary); 
    border-right: 1px solid var(--border);
    padding: 32px 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .nav-item {
    padding: 12px 16px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 14px;
    font-weight: 600;
    transition: all 0.2s;
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .nav-item:hover { background: var(--border); color: var(--text-primary); }
  .nav-item.active { background: var(--accent-glow); color: var(--accent); }

  .main { overflow-y: hidden; background: transparent; display: flex; flex-direction: column; }

  .panel { 
    padding: 24px 40px; 
    max-width: 1400px; 
    margin: 0 auto; 
    width: 100%;
    height: 100%;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .scroll-content {
    flex: 1;
    overflow-y: auto;
    padding-right: 12px;
    margin-top: 24px;
    scrollbar-width: thin;
    scrollbar-color: var(--border) transparent;
  }
  .scroll-content::-webkit-scrollbar { width: 6px; }
  .scroll-content::-webkit-scrollbar-track { background: transparent; }
  .scroll-content::-webkit-scrollbar-thumb { background: var(--border); border-radius: 10px; }

  .card {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 16px;
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    backdrop-filter: blur(12px);
    position: relative;
    overflow: hidden;
  }
  .card:hover { 
    transform: translateY(-4px); 
    border-color: var(--accent);
    box-shadow: 0 12px   .sort-bar {
    display: flex;
    gap: 12px;
    margin-bottom: 24px;
    align-items: center;
  }
  .sort-select {
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    color: var(--text-primary);
    padding: 6px 32px 6px 12px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    appearance: none;
    background-image: url("data:image/svg+xml;charset=UTF-8,%3csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3e%3cpolyline points='6 9 12 15 18 9'%3e%3c/polyline%3e%3c/svg%3e");
    background-repeat: no-repeat;
    background-position: right 8px center;
    background-size: 14px;
    outline: none;
    transition: all 0.2s;
  }
  .sort-select:hover { border-color: var(--accent); }

  .input {
    background: rgba(255,255,255,0.05);
    border: 1px solid var(--border);
    color: var(--text-primary);
    padding: 14px 20px;
    border-radius: 14px;
    width: 100%;
    outline: none;
    transition: all 0.2s;
    font-size: 14px;
  }
  .input:focus { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent-glow); }

  .input-icon-btn {
    position: absolute;
    right: 16px;
    top: 50%;
    transform: translateY(-50%);
    background: transparent;
    border: none;
    color: var(--text-secondary);
    cursor: pointer;
    display: flex;
    align-items: center;
    padding: 4px;
  }
  .input-icon-btn:hover { color: var(--accent); }

  .auth-container {
    background: rgba(10, 13, 20, 0.7);
    border: 1px solid var(--border);
    backdrop-filter: blur(40px);
    border-radius: 24px;
    padding: 48px 40px;
    box-shadow: 0 12px 48px rgba(0,0,0,0.5);
  }
  [data-theme='light'] .auth-container { background: rgba(255, 255, 255, 0.85); }

  .btn {
    padding: 10px 20px;
    border-radius: 12px;
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    font-size: 13px;
    font-weight: 600;
    transition: all 0.2s;
  }
  .btn:hover { background: var(--border); }
  .btn-accent { background: var(--accent); color: white; border: none; }
  .btn-accent:hover { opacity: 0.9; }
  .btn-danger { color: #FF6B6B; border-color: rgba(255,107,107,0.2); }
  .btn-danger:hover { background: rgba(255,107,107,0.1); }

  .doc-list {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 16px;
  }

  .header-right { display: flex; align-items: center; gap: 16px; }
  .sync-status-box {
    display: flex;
    align-items: center;
    gap: 8px;
    background: var(--border);
    padding: 6px 12px;
    border-radius: 10px;
    font-size: 10px;
    font-weight: 800;
    letter-spacing: 0.5px;
    color: var(--text-secondary);
  }
  .sync-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
  .sync-dot.online { background: #10B981; box-shadow: 0 0 8px rgba(16, 185, 129, 0.4); }
  .sync-dot.offline { background: #EF4444; }

  .theme-select {
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 11px;
    font-weight: 700;
    cursor: pointer;
    outline: none;
    padding: 4px;
    text-transform: uppercase;
  }
  .theme-select:hover { color: var(--text-primary); }
  .theme-select option { background: var(--bg-primary); color: var(--text-primary); }

  .toast-container { position:fixed; bottom:24px; right:24px; display:flex; flex-direction:column; gap:12px; z-index:2000; }
  .toast {
    padding:14px 18px; border:1px solid var(--border); background:var(--bg-secondary);
    font-size:13px; border-radius:12px; box-shadow:var(--card-shadow);
    backdrop-filter:blur(10px); color: var(--text-primary); min-width: 260px;
    animation: slideIn 0.3s cubic-bezier(0.175, 0.885, 0.32, 1.275);
  }
  @keyframes slideIn { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } }
  
  .did-box {
    padding: 16px; background: rgba(0,0,0,0.2); border-radius: 12px;
    font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #4A9EFF;
    word-break: break-all; margin: 20px 0; border: 1px solid rgba(74, 158, 255, 0.1);
  }
`;

// ── Password strength checker ──────────────────────────────────────────────
function checkPasswordRules(pw: string) {
  return {
    length: pw.length >= 12,
    upper: /[A-Z]/.test(pw),
    lower: /[a-z]/.test(pw),
    digit: /[0-9]/.test(pw),
    special: /[!@#$%^&*()\-_=+\[\]{};:'",.<>?\/\\|`~]/.test(pw),
  };
}

function allRulesPass(rules: ReturnType<typeof checkPasswordRules>) {
  return rules.length && rules.upper && rules.lower && rules.digit && rules.special;
}

function getAge(dobStr: string): number {
  if (!dobStr) return 0;
  const dob = new Date(dobStr);
  const today = new Date();
  let age = today.getFullYear() - dob.getFullYear();
  const m = today.getMonth() - dob.getMonth();
  if (m < 0 || (m === 0 && today.getDate() < dob.getDate())) age--;
  return age;
}

// ── Password Rules Component ───────────────────────────────────────────────
function PasswordRules({ password }: { password: string }) {
  const rules = checkPasswordRules(password);
  const passCount = Object.values(rules).filter(Boolean).length;
  const strengthPct = (passCount / 5) * 100;
  const strengthColor =
    passCount <= 1 ? "#FF6B6B" :
      passCount <= 3 ? "#FFB800" :
        passCount === 4 ? "#4A9EFF" : "#00E0C6";

  if (!password) return null;

  return (
    <div className="pw-rules">
      <div className="pw-strength-bar">
        <div className="pw-strength-fill" style={{ width: `${strengthPct}%`, background: strengthColor }} />
      </div>
      <div className="pw-rules-title">Security Requirements</div>
      {[
        { key: "length", label: "12+ Characters" },
        { key: "upper", label: "Uppercase Letter" },
        { key: "lower", label: "Lowercase Letter" },
        { key: "digit", label: "Number" },
        { key: "special", label: "Special Character" },
      ].map(r => (
        <div key={r.key} className={`pw-rule ${rules[r.key as keyof typeof rules] ? "ok" : ""}`}>
          <span className="pw-rule-icon">{rules[r.key as keyof typeof rules] ? "✓" : "○"}</span>
          {r.label}
        </div>
      ))}
    </div>
  );
}

let toastId = 0;

export default function App() {
  const [view, setView] = useState<"boot" | "auth" | "dashboard" | "error">("boot");
  const [username, setUsername] = useState<string | null>(() => localStorage.getItem("przma_username"));
  const [curPanel, setCurPanel] = useState<'library' | 'search' | 'settings'>('library');
  const [theme, setTheme] = useState<'prism'|'dark'|'light'>('prism');
  const [sortBy, setSortBy] = useState<'date'|'name'|'size'>('date');

  const [viewDoc, setViewDoc] = useState<Doc | null>(null);
  const [pendingEdit, setPendingEdit] = useState<{ id: string; localPath: string; version: number; filename: string } | null>(null);
  const [docs, setDocs] = useState<Doc[]>([]);
  const [toasts, setToasts] = useState<{ id: number, msg: string, type: string }[]>([]);
  const [isOnline, setIsOnline] = useState(navigator.onLine);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  const displayDocs = useMemo(() => {
    let list = [...docs];
    if (sortBy === 'date') list.sort((a,b) => new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime());
    else if (sortBy === 'name') list.sort((a,b) => (a.filename || "").localeCompare(b.filename || ""));
    else if (sortBy === 'size') list.sort((a,b) => (Number(b.file_size) || 0) - (Number(a.file_size) || 0));
    return list;
  }, [docs, sortBy]);

  // Auth state
  const [authMode, setAuthMode] = useState<"register" | "login" | "forgot">("register");
  const [regStep, setRegStep] = useState<2 | 3>(2);
  const [captcha, setCaptcha] = useState<{ token: string; data: string } | null>(null);
  const [regForm, setRegForm] = useState({ username: "", email: "", password: "", confirm: "", code: "", dateOfBirth: "" });
  const [loginForm, setLoginForm] = useState({ identifier: "", password: "" });
  const [regUserId, setRegUserId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [showRegPw, setShowRegPw] = useState(false);
  const [showLoginPw, setShowLoginPw] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [regMsg, setRegMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [loginMsg, setLoginMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [resetEmail, setResetEmail] = useState("");
  const [resetMsg, setResetMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [resetStep, setResetStep] = useState(1);

  const addToast = (msg: string, type: string = "info") => {
    const id = toastId++;
    setToasts(t => [...t, { id, msg, type }]);
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), 4000);
  };

  useEffect(() => {
    const up = () => setIsOnline(true);
    const down = () => setIsOnline(false);
    window.addEventListener("online", up);
    window.addEventListener("offline", down);
    return () => { window.removeEventListener("online", up); window.removeEventListener("offline", down); };
  }, []);

  useEffect(() => {
    const init = async () => {
      await new Promise(r => setTimeout(r, 1500));
      try {
        const storedDid = await invoke<string | null>("get_stored_did");
        if (storedDid) {
          setView("dashboard");
          loadDocs();
        } else {
          setView("auth");
        }
      } catch (err) { setView("error"); }
    };
    init();
  }, []);

  useEffect(() => {
    if (view === "dashboard") {
      const interval = setInterval(loadDocs, 5000);
      return () => clearInterval(interval);
    }
  }, [view]);

  const loadDocs = async () => {
    try {
      // Step 1: Call the Arrow-based command
      const result: { ipc_base64: string, record_count: number } = await invoke("get_documents_arrow");
      
      if (!result.ipc_base64) {
        setDocs([]);
        return;
      }

      // Step 2: Decode Arrow IPC buffer
      const binary = atob(result.ipc_base64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
      }
      
      const table = tableFromIPC(bytes);
      
      // Step 3: Convert Arrow rows to plain objects for the React state
      // This allows us to keep the rest of the UI logic identical while 
      // obtaining the data via the high-performance Arrow flow.
      const documents: Doc[] = [];
      const rowCount = table.numRows;
      
      // We iterate through the table to build our local state objects
      for (let i = 0; i < rowCount; i++) {
        const row = table.get(i);
        if (!row) continue;
        
        // Map Arrow columns to our Doc interface
        // Field names must match what's in analytics.rs
        documents.push({
          id: String(row.id),
          filename: String(row.filename),
          text_content: String(row.text_content || ""),
          is_synced: row.is_synced ? 1 : 0,
          status: String(row.status),
          created_at: String(row.created_at || ""),
          updated_at: String(row.updated_at || ""),
          content_type: String(row.content_type || ""),
          version: Number(row.local_version || 1),
          file_size: Number(row.file_size || 0),
          conflict_copy_of: null,
          tags: []
        });
      }
      
      setDocs(documents);
    }
    catch (err) { 
      console.error("Arrow doc load failed:", err);
      // Fallback to standard JSON if Arrow fails (optional, but good for robustness)
      try {
        setDocs(await invoke<Doc[]>("list_documents"));
      } catch (e) {
        console.error("Fallback load failed:", e);
      }
    }
  };

  const loadCaptcha = async () => {
    try {
      const res = await invoke<any>("get_captcha");
      setCaptcha({ token: res.token, data: res.answer_data });
    } catch (e) { addToast("Captcha failed", "error"); }
  };

  const handleLogin = async () => {
    if (!loginForm.identifier || !loginForm.password) return;
    setLoading(true); setLoginMsg(null);
    try {
      const result = await invoke<any>("login", { ...loginForm });
      if (result.success && result.did) {
        const uname = result.username ?? loginForm.identifier;
        setUsername(uname);
        localStorage.setItem("przma_username", uname);
        setView("dashboard");
        loadDocs();
        addToast("Welcome back", "success");
      } else {
        setLoginMsg({ text: "Invalid credentials", type: "error" });
      }
    } catch (e: any) { setLoginMsg({ text: e, type: "error" }); }
    finally { setLoading(false); }
  };

  const handleRegister = async () => {
    const pwRules = checkPasswordRules(regForm.password);
    if (!regForm.username || !regForm.email || !regForm.password || !regForm.dateOfBirth) {
      setRegMsg({ text: "All fields are required", type: "error" }); return;
    }
    if (!allRulesPass(pwRules)) {
      setRegMsg({ text: "Password requirements not met", type: "error" }); return;
    }
    if (regForm.password !== regForm.confirm) {
      setRegMsg({ text: "Passwords don't match", type: "error" }); return;
    }
    if (getAge(regForm.dateOfBirth) < 13) {
      setRegMsg({ text: "Must be 13 or older", type: "error" }); return;
    }

    setLoading(true); setRegMsg(null);
    try {
      const result = await invoke<any>("register_account", {
        nickname: regForm.username,
        email: regForm.email,
        password: regForm.password,
        captchaToken: captcha?.token,
        captchaSolution: regForm.code
      });
      if (result.success && result.user_id) {
        setRegUserId(result.user_id);
        setRegStep(3);
      }
    } catch (e: any) { setRegMsg({ text: e, type: "error" }); loadCaptcha(); }
    finally { setLoading(false); }
  };

  const handleVerifyEmail = async () => {
    if (!regUserId || !regForm.code) return;
    setLoading(true);
    try {
      await invoke("verify_email", { userId: regUserId, code: regForm.code });
      setUsername(regForm.username);
      localStorage.setItem("przma_username", regForm.username);
      setView("dashboard");
      loadDocs();
      addToast("Account Created", "success");
    } catch (e: any) { addToast(e, "error"); }
    finally { setLoading(false); }
  };

  const handleLogout = async () => {
    const ok = await confirm("Sign out of PRZMA?");
    if (!ok) return;
    await invoke("logout");
    setUsername(null);
    localStorage.removeItem("przma_username");
    setView("auth");
    setAuthMode("login");
  };

  const handleUpload = async () => {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({ multiple: true });
    if (!selected) return;
    const paths = Array.isArray(selected) ? selected : [selected];
    addToast("Syncing files...", "info");
    try {
      await invoke("upload_files_from_paths", { paths });
      loadDocs();
      addToast("Vault updated", "success");
    } catch (e: any) { addToast(e, "error"); }
  };

  const handleSaveEdit = async () => {
    if (!pendingEdit) return;
    setLoading(true);
    try {
      await invoke("save_edited_file", {
        id: pendingEdit.id,
        localPath: pendingEdit.localPath,
        currentVersion: pendingEdit.version,
      });
      setPendingEdit(null);
      loadDocs();
      addToast("Saved — version updated", "success");
    } catch (e: any) { addToast(e, "error"); }
    finally { setLoading(false); }
  };

  const handleDocDelete = async (id: string) => {
    if (await confirm("Permanently delete this artifact?")) {
      try {
        await invoke("delete_document", { id });
        setDocs(d => d.filter(x => x.id !== id));
        addToast("Deleted", "success");
      } catch (e: any) { addToast(e, "error"); }
    }
  };



  // ── Render Logic ──────────────────────────────────────────────────────────

  if (view === "boot") return (
    <div className="fullscreen" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <style>{css}</style>
      <div style={{ textAlign: 'center' }}>
        <div className="logo" style={{ fontSize: 64, marginBottom: 16 }}>PRZMA</div>
        <div style={{ fontSize: 11, opacity: 0.3, letterSpacing: 4 }}>INITIALIZING SECURE VAULT</div>
      </div>
    </div>
  );

  if (view === "auth") return (
    <div className="fullscreen" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <style>{css}</style>
      <div className="auth-container" style={{ width: 440 }}>
        <div style={{ textAlign: 'center', marginBottom: 40 }}>
          <div className="logo" style={{ fontSize: 40, letterSpacing: -2, background: 'linear-gradient(135deg, #58A6FF 0%, #00E0C6 100%)', WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent' }}>PRZMA</div>
          <div style={{ fontSize: 11, opacity: 0.6, marginTop: 8, letterSpacing: 2, fontWeight: 600 }}>DECENTRALIZED IDENTITY SYSTEM</div>
        </div>

        {authMode !== "forgot" && regStep !== 3 && (
          <div style={{ display: 'flex', gap: 6, marginBottom: 32, background: 'var(--bg-secondary)', padding: 6, border: '1px solid var(--border)', borderRadius: 16 }}>
            <button
              className={`btn ${authMode === "login" ? "active" : ""}`}
              style={{ flex: 1, border: 'none', background: authMode === "login" ? 'rgba(74, 158, 255, 0.1)' : 'transparent', color: authMode === "login" ? '#4A9EFF' : 'rgba(255,255,255,0.3)' }}
              onClick={() => { setAuthMode("login"); setLoginMsg(null); }}
            >
              Sign In
            </button>
            <button
              className={`btn ${authMode === "register" ? "active" : ""}`}
              style={{ flex: 1, border: 'none', background: authMode === "register" ? 'rgba(74, 158, 255, 0.1)' : 'transparent', color: authMode === "register" ? '#4A9EFF' : 'rgba(255,255,255,0.3)' }}
              onClick={() => { setAuthMode("register"); setRegMsg(null); if (!captcha) loadCaptcha(); }}
            >
              Create Account
            </button>
          </div>
        )}

        <div style={{ position: 'relative' }}>
          {authMode === "register" && (
            regStep === 2 ? (
              <div>
                {regMsg && <div style={{ color: regMsg.type === 'error' ? '#FF6B6B' : '#00E0C6', fontSize: 13, marginBottom: 16, textAlign: 'center' }}>{regMsg.text}</div>}
                <div className="input-group">
                  <input className="input" placeholder="Username" value={regForm.username} onChange={e => setRegForm({ ...regForm, username: e.target.value })} />
                </div>
                <div className="input-group">
                  <input className="input" placeholder="Email" value={regForm.email} onChange={e => setRegForm({ ...regForm, email: e.target.value })} />
                </div>

                <div className="dob-row">
                  <div className="input-group">
                    <input className="input" type="date" value={regForm.dateOfBirth} onChange={e => setRegForm({ ...regForm, dateOfBirth: e.target.value })} />
                  </div>
                  <div className={`age-badge ${regForm.dateOfBirth ? (getAge(regForm.dateOfBirth) >= 13 ? "ok" : "err") : ""}`}>
                    {regForm.dateOfBirth ? `${getAge(regForm.dateOfBirth)}Y` : "--"}
                  </div>
                </div>

                <div className="input-group">
                  <input className="input" placeholder="Password" type={showRegPw ? "text" : "password"} value={regForm.password} onChange={e => setRegForm({ ...regForm, password: e.target.value })} />
                  <button className="input-icon-btn" onClick={() => setShowRegPw(!showRegPw)}>{showRegPw ? <EyeClosedIcon /> : <EyeOpenIcon />}</button>
                </div>

                <div className="input-group">
                  <input className="input" placeholder="Confirm Password" type="password" value={regForm.confirm} onChange={e => setRegForm({ ...regForm, confirm: e.target.value })} />
                </div>

                <PasswordRules password={regForm.password} />

                {captcha && (
                  <div className="captcha-box">
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12 }}>
                      <div className="captcha-img" style={{ flex: 1, marginBottom: 0 }} dangerouslySetInnerHTML={{ __html: captcha.data }} />
                      <button
                        type="button"
                        onClick={loadCaptcha}
                        title="Refresh captcha"
                        style={{ flexShrink: 0, background: 'transparent', border: '1px solid rgba(255,255,255,0.08)', borderRadius: 8, padding: '8px', cursor: 'pointer', color: 'rgba(255,255,255,0.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', transition: 'all 0.2s' }}
                        onMouseEnter={e => (e.currentTarget.style.color = '#4A9EFF', e.currentTarget.style.borderColor = 'rgba(74,158,255,0.3)')}
                        onMouseLeave={e => (e.currentTarget.style.color = 'rgba(255,255,255,0.4)', e.currentTarget.style.borderColor = 'rgba(255,255,255,0.08)')}
                      >
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                          <polyline points="23 4 23 10 17 10" />
                          <polyline points="1 20 1 14 7 14" />
                          <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15" />
                        </svg>
                      </button>
                    </div>
                    <input className="input" style={{ marginBottom: 0 }} placeholder="Enter characters above" value={regForm.code} onChange={e => setRegForm({ ...regForm, code: e.target.value })} />
                  </div>
                )}

                <button className="btn" style={{ width: '100%', background: '#4A9EFF', color: '#fff', border: 'none', height: 52 }} onClick={handleRegister} disabled={loading}>
                  {loading ? "Creating Identity..." : "Establish Identity"}
                </button>
              </div>
            ) : (
              <div>
                <h3 style={{ textAlign: 'center', marginBottom: 16 }}>Confirm Email</h3>
                <p style={{ color: 'rgba(255,255,255,0.4)', textAlign: 'center', marginBottom: 24, fontSize: 13 }}>We sent a verification code to {regForm.email}</p>
                <div className="input-group">
                  <input className="input" placeholder="6-digit code" style={{ textAlign: 'center', letterSpacing: 8, fontSize: 24 }} value={regForm.code} onChange={e => setRegForm({ ...regForm, code: e.target.value })} />
                </div>
                <button className="btn" style={{ width: '100%', background: '#4A9EFF', color: '#fff', border: 'none', height: 52 }} onClick={handleVerifyEmail} disabled={loading}>
                  {loading ? "Verifying..." : "Complete Registration"}
                </button>
              </div>
            )
          )}

          {authMode === "login" && (
            <div>
              {loginMsg && <div style={{ color: '#FF6B6B', fontSize: 13, marginBottom: 16, textAlign: 'center' }}>{loginMsg.text}</div>}
              <div className="input-group">
                <input className="input" placeholder="Username or Email" value={loginForm.identifier} onChange={e => setLoginForm({ ...loginForm, identifier: e.target.value })} />
              </div>
              <div className="input-group">
                <input className="input" placeholder="Password" type={showLoginPw ? "text" : "password"} value={loginForm.password} onChange={e => setLoginForm({ ...loginForm, password: e.target.value })} />
                <button className="input-icon-btn" onClick={() => setShowLoginPw(!showLoginPw)}>{showLoginPw ? <EyeClosedIcon /> : <EyeOpenIcon />}</button>
              </div>
              <button className="btn" style={{ width: '100%', background: '#4A9EFF', color: '#fff', border: 'none', height: 52, marginTop: 12 }} onClick={handleLogin} disabled={loading}>
                {loading ? "Authenticating..." : "Sign In"}
              </button>
              <div style={{ textAlign: 'center', marginTop: 20 }}>
                <a href="#" style={{ color: 'rgba(255,255,255,0.3)', fontSize: 12, textDecoration: 'none' }} onClick={e => { e.preventDefault(); setAuthMode("forgot"); }}>Forgot password?</a>
              </div>
            </div>
          )}

          {authMode === "forgot" && (
            <div>
              <h3 style={{ textAlign: 'center', marginBottom: 16 }}>Reset Password</h3>
              <div className="input-group">
                <input className="input" placeholder="Account Email" value={resetEmail} onChange={e => setResetEmail(e.target.value)} />
              </div>
              <button className="btn" style={{ width: '100%', background: '#4A9EFF', color: '#fff', border: 'none' }}>Send Reset Link</button>
              <div style={{ textAlign: 'center', marginTop: 20 }}>
                <a href="#" style={{ color: 'rgba(255,255,255,0.3)', fontSize: 12, textDecoration: 'none' }} onClick={e => { e.preventDefault(); setAuthMode("login"); }}>Back to Login</a>
              </div>
            </div>
          )}
        </div>
      </div>
      <div className="toast-container">{toasts.map(t => <div key={t.id} className="toast">{t.msg}</div>)}</div>
    </div>
  );

  return (
    <>
      <style>{css}</style>
      <div className="prism-bg">
        <div className="prism-orb" style={{ top: '-10%', left: '-10%', background: 'rgba(74, 158, 255, 0.3)' }} />
        <div className="prism-orb" style={{ bottom: '-10%', right: '-10%', background: 'rgba(255, 184, 0, 0.2)' }} />
        <div className="prism-orb" style={{ top: '40%', left: '30%', background: 'rgba(0, 224, 198, 0.15)', width: 400, height: 400 }} />
      </div>

      <div className="app-container">
        <header className="header">
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ fontSize: 24, fontWeight: 900, letterSpacing: -1, background: 'linear-gradient(135deg, #58A6FF 0%, #00E0C6 100%)', WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent' }}>PRZMA</div>
          </div>

          <div className="header-right">
            <div className="sync-status-box">
              <span className={`sync-dot ${isOnline ? 'online' : 'offline'}`} />
              <span style={{ fontSize: 10, fontWeight: 800 }}>{isOnline ? 'ONLINE' : 'OFFLINE'}</span>
            </div>
            
            <div style={{ display: 'flex', alignItems: 'center', gap: 16, borderLeft: '1px solid var(--border)', paddingLeft: 16 }}>
              <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--text-primary)' }}>{username || 'Account'}</span>
              
              <select 
                className="theme-select" 
                value={theme} 
                onChange={(e) => setTheme(e.target.value as any)}
                title="Theme"
              >
                <option value="prism">PRISM</option>
                <option value="dark">DARK</option>
                <option value="light">LIGHT</option>
              </select>

              <button 
                className="btn" 
                style={{ height: 32, padding: '0 12px', fontSize: 11, background: 'rgba(239, 68, 68, 0.05)', color: '#EF4444', borderColor: 'rgba(239, 68, 68, 0.2)' }} 
                onClick={handleLogout}
              >
                Logout
              </button>
            </div>
          </div>
        </header>

        <nav className="sidebar">
          <button className={`nav-item ${curPanel === 'library' ? 'active' : ''}`} onClick={() => setCurPanel('library')}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>
            Library
          </button>
          <button className={`nav-item upload-btn`} style={{ marginTop: 8, background: 'linear-gradient(135deg, rgba(88,166,255,0.15) 0%, rgba(0,224,198,0.1) 100%)', border: '1px solid var(--border)', color: 'var(--accent)' }} onClick={handleUpload}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            <span style={{ fontWeight: 800 }}>Upload Item</span>
          </button>
          <div style={{ flex: 1 }} />
          <div style={{ padding: 12, borderRadius: 12, background: 'var(--accent-glow)', border: '1px solid var(--accent)', color: 'var(--accent)', fontSize: 11, fontWeight: 600 }}>
            <div style={{ marginBottom: 4 }}>PRZMA Node Beta</div>
            <div style={{ opacity: 0.7 }}>Secure P2P Storage Active</div>
          </div>
        </nav>

        <main className="main">
          {curPanel === 'library' && (
            <div className="panel">
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', marginBottom: 20 }}>
                <div>
                  <h1 style={{ fontSize: 32, fontWeight: 900, marginBottom: 4 }}>Vault Library</h1>
                  <p style={{ color: 'var(--text-secondary)', fontSize: 14 }}>{docs.length} artifacts secured via distributed encryption</p>
                </div>
                <div className="sort-bar">
                  <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--text-secondary)', marginRight: 4 }}>SORT BY</span>
                  <select 
                    className="sort-select" 
                    value={sortBy} 
                    onChange={e => setSortBy(e.target.value as any)}
                  >
                    <option value="date">Date</option>
                    <option value="name">Name</option>
                    <option value="size">Size</option>
                  </select>
                </div>
              </div>

              <input className="input" placeholder="Filter vault..." value={searchQuery} onChange={e => setSearchQuery(e.target.value)} />

              <div className="scroll-content">
                <div className="doc-list">
                  {displayDocs.filter((d: Doc) => d.filename.toLowerCase().includes(searchQuery.toLowerCase())).map((d: Doc) => (
                    <div key={d.id} className="card">
                      <div className="thumbnail-box">
                        <Thumbnail type={d.content_type || ''} filename={d.filename} id={d.id} />
                      </div>
                      
                      <div className="doc-name">{d.filename}</div>
                      <div className="doc-meta">
                        {formatFileSize(d.file_size)} · {new Date(d.updated_at).toLocaleDateString()} at {new Date(d.updated_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                      </div>

                      <div style={{ display: 'flex', gap: 8, marginTop: 20 }}>
                        <button className="btn doc-action-btn" style={{ flex: 1, height: 36, background: 'var(--border)' }} title="View" onClick={() => setViewDoc(d)}><IconView /></button>
                        
                        <button className="btn doc-action-btn" style={{ width: 44, height: 36 }} title="Edit" onClick={async () => {
                          addToast("Accessing file...", "info");
                          try {
                            const localPath = await invoke<string>("open_file_for_edit", { id: d.id, filename: d.filename });
                            setPendingEdit({ id: d.id, localPath, version: d.version, filename: d.filename });
                          } catch (e: any) { addToast(e, "error"); }
                        }}><IconEdit /></button>

                        <button className="btn doc-action-btn" title="Download" style={{ width: 44, height: 36, color: 'var(--accent)', borderColor: 'var(--accent-glow)' }} onClick={async () => {
                          const { save } = await import("@tauri-apps/plugin-dialog");
                          const { writeFile } = await import("@tauri-apps/plugin-fs");
                          const savePath = await save({ defaultPath: d.filename });
                          if (!savePath) return;
                          addToast("Downloading...", "info");
                          try {
                            const bytes = await invoke<number[]>("get_file_bytes", { id: d.id });
                            await writeFile(savePath, new Uint8Array(bytes));
                            addToast("File saved safely", "success");
                          } catch (e: any) { addToast(e, "error"); }
                        }}><IconDownload /></button>

                        <button className="btn doc-action-btn btn-danger" style={{ width: 44, height: 36 }} title="Delete" onClick={() => handleDocDelete(d.id)}><IconDelete /></button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          )}
        </main>

        {viewDoc && (
          <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', zIndex: 500, display: 'flex', alignItems: 'center', justifyContent: 'center' }} onClick={() => setViewDoc(null)}>
            <div style={{ width: '70%', maxHeight: '80vh', background: '#0d1117', border: '1px solid rgba(255,255,255,0.08)', borderRadius: 16, padding: 32, overflow: 'hidden', display: 'flex', flexDirection: 'column' }} onClick={e => e.stopPropagation()}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
                <div>
                  <div style={{ fontWeight: 700, fontSize: 16 }}>{viewDoc.filename}</div>
                  <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.3)', fontFamily: 'JetBrains Mono', marginTop: 4 }}>
                    {new Date(viewDoc.updated_at).toLocaleDateString()} · {new Date(viewDoc.updated_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })} · V{viewDoc.version || 1}
                  </div>
                </div>
                <button className="btn" style={{ fontSize: 11 }} onClick={() => setViewDoc(null)}>✕ Close</button>
              </div>
              <pre style={{ flex: 1, overflow: 'auto', fontFamily: 'JetBrains Mono', fontSize: 12, color: '#c9d1d9', lineHeight: 1.7, whiteSpace: 'pre-wrap', wordBreak: 'break-word', background: 'rgba(0,0,0,0.2)', padding: 20, borderRadius: 10, border: '1px solid rgba(255,255,255,0.05)' }}>
                {viewDoc.text_content || "(No text content available for this file type)"}
              </pre>
            </div>
          </div>
        )}

      </div>
      {pendingEdit && (
        <div style={{ position: 'fixed', bottom: 24, left: '50%', transform: 'translateX(-50%)', zIndex: 1000, background: 'rgba(13,17,23,0.95)', border: '1px solid rgba(74,158,255,0.3)', borderRadius: 14, padding: '14px 20px', display: 'flex', alignItems: 'center', gap: 16, backdropFilter: 'blur(12px)', boxShadow: '0 8px 32px rgba(0,0,0,0.4)', minWidth: 360 }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: '#F0F4F8' }}>Editing: {pendingEdit.filename}</div>
            <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.3)', marginTop: 2 }}>Save the file in your editor, then click Save Changes to update the version</div>
          </div>
          <button className="btn" style={{ fontSize: 11, background: '#4A9EFF', color: '#fff', border: 'none', whiteSpace: 'nowrap' }} onClick={handleSaveEdit} disabled={loading}>
            {loading ? "Saving..." : "Save Changes"}
          </button>
          <button className="btn" style={{ fontSize: 11, padding: '8px 12px' }} onClick={() => setPendingEdit(null)}>✕</button>
        </div>
      )}

      <div className="toast-container">{toasts.map(t => <div key={t.id} className={`toast`}>{t.msg}</div>)}</div>
    </>
  );
}
