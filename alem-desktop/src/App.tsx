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

// ── Password strength checker ──────────────────────────────────────────────
function checkPasswordRules(pw: string) {
  return {
    length:  pw.length >= 12,
    upper:   /[A-Z]/.test(pw),
    lower:   /[a-z]/.test(pw),
    digit:   /[0-9]/.test(pw),
    special: /[!@#$%^&*()\-_=+\[\]{};:'",.<>?\/\\|`~]/.test(pw),
  };
}

function allRulesPass(rules: ReturnType<typeof checkPasswordRules>) {
  return rules.length && rules.upper && rules.lower && rules.digit && rules.special;
}

// ── Age validation ─────────────────────────────────────────────────────────
function getAge(dobStr: string): number {
  if (!dobStr) return 0;
  const dob = new Date(dobStr);
  const today = new Date();
  let age = today.getFullYear() - dob.getFullYear();
  const m = today.getMonth() - dob.getMonth();
  if (m < 0 || (m === 0 && today.getDate() < dob.getDate())) age--;
  return age;
}

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
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap');

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body, html, #root {
    height: 100%;
    background: #08090d;
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
    border-bottom: 1px solid #1c2333;
    background: rgba(10, 14, 27, 0.8);
    backdrop-filter: blur(12px);
    box-shadow: 0 4px 16px rgba(0,0,0,0.2);
    z-index: 10;
  }

  .logo {
    font-size: 22px;
    font-weight: 700;
    letter-spacing: 4px;
    background: linear-gradient(135deg, #4A9EFF 0%, #FFB800 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
    text-shadow: 0 0 20px rgba(74, 158, 255, 0.3);
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 24px;
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
    border-right: 1px solid #1c2333;
    background: #0d1117;
    padding: 24px 16px;
    overflow-y: auto;
    box-shadow: 4px 0 20px rgba(0,0,0,0.3);
  }

  .nav-item {
    padding: 12px 16px;
    margin-bottom: 8px;
    cursor: pointer;
    border-radius: 10px;
    transition: all 0.2s cubic-bezier(0.4,0,0.2,1);
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-weight: 500;
    color: #8b949e;
    border: 1px solid transparent;
  }
  .nav-item:hover { background: rgba(74,158,255,0.05); color: #F0F4F8; border-color: rgba(74,158,255,0.2); }
  .nav-item.active { background: rgba(74,158,255,0.15); color: #4A9EFF; border-color: rgba(74,158,255,0.4); box-shadow: 0 0 0 1px rgba(74,158,255,0.1); }

  .badge { background: #FF6B6B; color:#fff; padding: 3px 9px; font-size:11px; font-weight:600; border-radius:12px; box-shadow: 0 2px 6px rgba(255,107,107,0.4); }

  .main { overflow-y: auto; background: #08090d; }

  .panel { padding: 32px; max-width: 1200px; }

  .panel-title {
    font-size: 32px; font-weight: 700; margin-bottom: 8px; letter-spacing: -0.5px;
    color: #F0F4F8;
  }
  .panel-sub { color:#8b949e; font-size:14px; margin-bottom:32px; }

  .card { border:1px solid #21262d; padding:24px; margin-bottom:20px; background:#0d1117; border-radius:12px; box-shadow:0 8px 24px rgba(0,0,0,0.3); }

  .doc-list { display:flex; flex-direction:column; gap:12px; }

  .doc-item {
    border:1px solid #21262d; padding:16px;
    display:flex; align-items:center; justify-content:space-between;
    background:#0d1117;
    border-radius:10px; transition:all 0.2s;
  }
  .doc-item:hover { border-color:#4A9EFF; background:rgba(74,158,255,0.05); transform:translateY(-2px); }
  .doc-item.latest-item { border-color: #FFB800; box-shadow: 0 0 12px rgba(255,184,0,0.15); }

  .doc-info { flex:1; min-width:0; }
  .doc-name { font-weight:600; margin-bottom:4px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; color:#F0F4F8; }
  .doc-meta { font-size:12px; color:#8b949e; font-family:'JetBrains Mono',monospace; }
  .doc-conflict { color: #FF6B6B; font-size: 11px; margin-left: 8px; font-weight: 600; }

  .doc-status { display:flex; align-items:center; gap:12px; }

  .tag { font-size:10px; padding:5px 12px; font-weight:600; text-transform:uppercase; letter-spacing:0.5px; border-radius:6px; font-family:'JetBrains Mono',monospace; }
  .tag-synced  { background:rgba(0,224,198,0.15); color:#00E0C6; border: 1px solid rgba(0,224,198,0.3); }
  .tag-pending { background:rgba(255,184,0,0.15); color:#FFB800; border: 1px solid rgba(255,184,0,0.3); }
  .tag-failed  { background:rgba(255,107,107,0.15); color:#FF6B6B; border: 1px solid rgba(255,107,107,0.3); }
  .tag-latest  { background: linear-gradient(135deg,#FFB800,#FF8C00); color:#0A0E27; box-shadow:0 2px 8px rgba(255,184,0,0.4); }

  .btn {
    padding:12px 20px; border:1px solid #30363d; background:transparent;
    color:#F0F4F8; font-family:'Inter',sans-serif; font-size:13px; font-weight:600;
    cursor:pointer; transition:all 0.2s cubic-bezier(0.4,0,0.2,1); border-radius:8px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
  }
  .btn:hover { background:#4A9EFF; border-color:#4A9EFF; color:#fff; transform:translateY(-2px); box-shadow:0 6px 20px rgba(74,158,255,0.4); }
  .btn:active { transform:translateY(0); }
  .btn:disabled { opacity:0.4; cursor:not-allowed; transform:none; background: #21262d; border-color: #21262d; color: #484f58; }

  .btn-danger { border-color:#FF6B6B; color:#FF6B6B; }
  .btn-danger:hover { background:#FF6B6B; border-color:#FF6B6B; color:#fff; box-shadow:0 6px 20px rgba(255,107,107,0.4); }

  .btn-secondary { background:#161b22; border-color:#30363d; }
  .btn-secondary:hover { background:#30363d; border-color:#30363d; box-shadow:0 6px 20px rgba(30,58,95,0.4); }

  .btn-success { border-color:#00E0C6; color:#00E0C6; }
  .btn-success:hover { background:#00E0C6; border-color:#00E0C6; color:#0A0E27; box-shadow:0 6px 20px rgba(0,224,198,0.4); }

  .input-group {
    position: relative;
    margin-bottom: 16px;
    width: 100%;
  }
  
  .input {
    width:100%; padding:12px 40px 12px 16px; background:#0d1117; border:1px solid #30363d;
    color:#F0F4F8; font-family:'Inter',sans-serif; font-size:14px; outline:none;
    border-radius:8px; transition:all 0.2s;
  }
  .input:not([type="password"]) {
    padding-right: 16px;
  }
  
  .input:focus { border-color:#4A9EFF; box-shadow:0 0 0 3px rgba(74,158,255,0.15); background: #161b22; }
  .input::placeholder { color:#484f58; opacity:1; }
  .input.input-error { border-color:#FF6B6B; }
  .input.input-ok    { border-color:#00E0C6; }
  textarea.input { resize:vertical; font-family:'JetBrains Mono',monospace; line-height:1.6; padding-right: 16px; }
  
  .input-icon-btn {
    position: absolute;
    right: 12px;
    top: 50%;
    transform: translateY(-50%);
    background: transparent;
    border: none;
    padding: 4px;
    cursor: pointer;
    color: #8b949e;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s;
    height: 20px;
  }
  
  .input-icon-btn:hover {
    color: #F0F4F8;
  }

  input[type="date"].input {
    color-scheme: dark;
  }
  input[type="date"].input::-webkit-calendar-picker-indicator {
    filter: invert(0.7) sepia(1) saturate(2) hue-rotate(190deg);
    cursor: pointer;
  }

  .pw-rules {
    background: #0d1117;
    border: 1px solid #21262d;
    border-radius: 8px;
    padding: 14px 16px;
    margin-bottom: 16px;
  }
  .pw-rules-title {
    font-size: 11px;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.8px;
    margin-bottom: 10px;
    font-weight: 600;
  }
  .pw-rule {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: #484f58;
    padding: 2px 0;
    transition: color 0.2s;
    font-family: 'JetBrains Mono', monospace;
  }
  .pw-rule.ok { color: #3fb950; }
  .pw-rule-icon { width: 14px; text-align: center; font-size: 11px; }
  .pw-strength-bar {
    height: 3px;
    border-radius: 2px;
    margin-bottom: 10px;
    background: #21262d;
    overflow: hidden;
  }
  .pw-strength-fill {
    height: 100%;
    border-radius: 2px;
    transition: width 0.3s, background 0.3s;
  }

  .dob-row {
    display: flex;
    gap: 12px;
    align-items: flex-start;
    margin-bottom: 16px;
  }
  .dob-row .input-group { flex: 1; margin-bottom: 0; }
  
  .age-badge {
    padding: 12px 14px;
    border-radius: 8px;
    font-size: 13px;
    font-weight: 700;
    white-space: nowrap;
    font-family: 'JetBrains Mono', monospace;
    border: 1px solid #30363d;
    background: #0d1117;
    color: #8b949e;
    min-width: 70px;
    text-align: center;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .age-badge.ok  { border-color:#00E0C6; color:#00E0C6; background:rgba(0,224,198,0.05); }
  .age-badge.err { border-color:#FF6B6B; color:#FF6B6B; background:rgba(255,107,107,0.05); }

  .field-label {
    font-size: 12px;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    font-weight: 600;
    margin-bottom: 8px;
    display: block;
  }

  .empty { text-align:center; padding:64px; color:#8b949e; border:2px dashed #30363d; border-radius:12px; background:rgba(13,17,23,0.5); }
  .empty-icon { font-size:56px; margin-bottom:16px; opacity:0.3; }

  .toast-container { position:fixed; bottom:24px; right:24px; display:flex; flex-direction:column; gap:12px; z-index:999; }

  .toast {
    padding:14px 18px; border:1px solid #30363d; background:#0d1117;
    font-size:13px; animation:slideIn 0.3s cubic-bezier(0.4,0,0.2,1);
    min-width:300px; border-radius:10px; box-shadow:0 8px 32px rgba(0,0,0,0.6);
    backdrop-filter:blur(10px);
  }
  .toast.error   { border-color:#FF6B6B; background:rgba(13,17,23,0.9); color:#FF6B6B; }
  .toast.success { border-color:#00E0C6; background:rgba(13,17,23,0.9); color:#00E0C6; }
  .toast.info    { border-color:#FFB800; background:rgba(13,17,23,0.9); color:#FFB800; }

  @keyframes slideIn {
    from { transform:translateX(100%); opacity:0; }
    to   { transform:translateX(0);    opacity:1; }
  }

  .fullscreen {
    height: 100%;
    width: 100%;
    position: absolute;
    top: 0;
    left: 0;
    background: radial-gradient(circle at top center, #101622 0%, #08090d 100%);
    color:#F0F4F8;
    overflow-y: auto;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: 40px 20px;
  }

  .boot-logo {
    font-size:72px; font-weight:700; letter-spacing:4px; margin-bottom:40px;
    background:linear-gradient(135deg,#4A9EFF 0%,#FFB800 100%);
    -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;
    animation:pulse 2s infinite;
  }

  .boot-steps { display:flex; flex-direction:column; gap:12px; font-size:14px; color:#8b949e; }

  .auth-container {
    max-width: 460px;
    width: 100%;
    padding: 32px;
    background: rgba(13, 17, 23, 0.8);
    border: 1px solid #21262d;
    border-radius: 16px;
    box-shadow: 0 16px 48px rgba(0,0,0,0.5);
    backdrop-filter: blur(12px);
    margin: auto;
  }

  .auth-title {
    font-size:36px; font-weight:700; margin-bottom:8px; letter-spacing:3px;
    background:linear-gradient(135deg,#4A9EFF 0%,#FFB800 100%);
    -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;
    text-align: center;
  }
  .auth-sub { color:#8b949e; font-size:13px; margin-bottom:24px; text-align: center; }

  .auth-tabs {
    display:flex;
    gap:0;
    margin-bottom:24px;
    border:1px solid #21262d;
    border-radius:8px;
    overflow:hidden;
    background: #0d1117;
  }
  .auth-tab {
    flex:1;
    padding:12px;
    text-align:center;
    cursor:pointer;
    font-size:13px;
    font-weight:600;
    color:#8b949e;
    background:transparent;
    border:none;
    transition:all 0.2s;
  }
  .auth-tab.active {
    background:rgba(74,158,255,0.15);
    color:#4A9EFF;
  }

  .captcha-box {
    border:1px solid #21262d; padding:20px;
    background:#0d1117;
    margin-bottom:20px; border-radius:12px;
    text-align: center;
    min-height: 90px;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
  }
  .captcha-label { font-size:11px; color:#8b949e; margin-bottom:8px; text-transform:uppercase; letter-spacing:0.5px; font-weight:500; }
  .captcha-code { font-size:36px; font-weight:700; letter-spacing:4px; font-family:'JetBrains Mono',monospace; color:#4A9EFF; text-shadow:0 0 20px rgba(74,158,255,0.3); }

  .btn-group { display:flex; gap:12px; }
  .btn-group .btn { flex:1; }

  .did-box {
    border:1px solid #21262d; padding:16px; background:#0d1117;
    word-break:break-all; font-size:12px; line-height:1.8; margin:20px 0;
    border-radius:10px; font-family:'JetBrains Mono',monospace; color:#4A9EFF;
    box-shadow:inset 0 2px 8px rgba(0,0,0,0.2);
  }

  .divider { height:1px; background:#21262d; margin:24px 0; }

  .status-bar {
    border-bottom:1px solid #21262d; padding:16px 32px;
    display:flex; gap:24px; font-size:13px;
    background: #0d1117;
    box-shadow: 0 4px 12px rgba(0,0,0,0.2);
    margin-bottom: 20px;
  }
  .status-item { color:#8b949e; }
  .status-item strong { color:#F0F4F8; font-weight:600; margin-left:6px; }

  .label {
    font-size:12px; color:#8b949e; text-transform:uppercase;
    letter-spacing:0.5px; font-weight:500; margin-bottom:8px; display:block;
  }

  .alert {
    padding:14px 18px; border-radius:8px; font-size:13px; margin-bottom:20px; border:1px solid;
  }
  .alert-success { border-color:rgba(0,224,198,0.3); background:rgba(0,224,198,0.1); color:#00E0C6; }
  .alert-error   { border-color:rgba(255,107,107,0.3); background:rgba(255,107,107,0.1); color:#FF6B6B; }

  .version-tag {
    font-size: 10px; color: #8b949e;
    background: rgba(33, 38, 45, 0.8);
    padding: 2px 6px; border-radius: 4px; margin-left: 8px; vertical-align: middle;
    font-family: 'JetBrains Mono', monospace;
  }

  a { color: #4A9EFF; text-decoration: none; transition: color 0.2s; }
  a:hover { color: #FFB800; }
`;

let toastId = 0;

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
      <div className="pw-rules-title">Password Requirements</div>
      {[
        { key: "length",  label: "At least 12 characters" },
        { key: "upper",   label: "One uppercase letter (A–Z)" },
        { key: "lower",   label: "One lowercase letter (a–z)" },
        { key: "digit",   label: "One digit (0–9)" },
        { key: "special", label: "One special character (!@#$% etc.)" },
      ].map(r => (
        <div key={r.key} className={`pw-rule ${rules[r.key as keyof typeof rules] ? "ok" : ""}`}>
          <span className="pw-rule-icon">{rules[r.key as keyof typeof rules] ? "✓" : "○"}</span>
          {r.label}
        </div>
      ))}
    </div>
  );
}

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
  const [regStep, setRegStep] = useState<2 | 3>(2);
  const [captcha, setCaptcha] = useState<{ token: string; answer: string } | null>(null);
  const [regForm, setRegForm] = useState({
    username: "", email: "", password: "", confirm: "",
    code: "", dateOfBirth: "",
  });
  const [regMsg, setRegMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [regLoading, setRegLoading] = useState(false);
  const [regUserId, setRegUserId] = useState<string | null>(null);

  const [loginForm, setLoginForm] = useState({ identifier: "", password: "" });
  const [loginMsg, setLoginMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [loginLoading, setLoginLoading] = useState(false);

  // Reset Password
  const [resetStep, setResetStep] = useState<1 | 2>(1);
  const [resetEmail, setResetEmail] = useState("");
  const [resetForm, setResetForm] = useState({ userId: "", token: "", password: "", confirm: "" });
  const [resetMsg, setResetMsg] = useState<{ text: string; type: "success" | "error" } | null>(null);

  // UI Visibility State
  const [showRegPw, setShowRegPw] = useState(false);
  const [showRegConfirmPw, setShowRegConfirmPw] = useState(false);
  const [showLoginPw, setShowLoginPw] = useState(false);
  const [showResetPw, setShowResetPw] = useState(false);

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
        setDocs(prevDocs =>
          prevDocs.map(d => d.id === id ? { ...d, status, is_synced: status === "synced" ? 1 : 0 } : d)
        );
        loadSyncStatus();
      });
    }
  }, []);

  // ── Deep link listener (for password reset from email) ──
  useEffect(() => {
    if (typeof window !== 'undefined' && (window as any).__TAURI__) {
      const unlisten = listen<string>('deep-link-received', (event) => {
        try {
          const urlString = event.payload;
          const match = urlString.match(/user_id=([^&]*)&token=([^&]*)/);
          if (match) {
            const userId = match[1];
            const token  = decodeURIComponent(match[2]);
            if (userId && token) {
              setResetForm({ userId, token, password: "", confirm: "" });
              setResetStep(2);
              setView("auth");
              setAuthMode("forgot");
              addToast("✅ Reset link verified — enter your new password", "success");
            } else {
              addToast("❌ Invalid reset link", "error");
            }
          }
        } catch (e) {
          console.error("Deep link parse error:", e);
        }
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
          try { await invoke("sync_now"); } catch (_) {}
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

  // ── Auto-load Captcha on Auth Mode Change ──
  useEffect(() => {
    if (view === "auth" && authMode === "register" && !captcha) {
      loadCaptcha();
    }
  }, [authMode, view]);

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
      setRegStep(2);
      setRegForm({ username: "", email: "", password: "", confirm: "", code: "", dateOfBirth: "" });
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
      addToast("❌ Content cannot be empty", "error"); return;
    }
    try {
      await invoke("update_document", { id: editingDoc.id, textContent: editingDoc.text_content });
      addToast("✅ Document updated & syncing...", "success");
      setEditingDoc(null);
      loadDocs(); loadSyncStatus();
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
        const base64 = btoa(new Uint8Array(arrayBuffer).reduce((data, byte) => data + String.fromCharCode(byte), ''));
        await invoke("upload_file", { filename: file.name, contentType: file.type || "application/octet-stream", fileDataB64: base64 });
        addToast(`✅ ${file.name} uploaded!`, "success");
        loadDocs(); setTab("docs");
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
      const path = await invoke<string>("open_file_for_edit", { id: editingDoc.id, filename: editingDoc.filename });
      setLocalPath(path);
      addToast("📂 File opened! Edit, SAVE in your external app, then click 'Upload Update'.", "info");
    } catch (err) { addToast(`Error: ${err}`, "error"); }
  };

  const handleBinarySave = async () => {
    if (!editingDoc || !localPath) return;
    try {
      const result = await invoke<string>("save_edited_file", { id: editingDoc.id, localPath, currentVersion: editingDoc.version });
      if (result === "NO_CHANGES") {
        addToast("⚠️ No changes detected. Please SAVE the file in your editor first.", "error");
      } else {
        addToast("✅ File saved and syncing!", "success");
        setEditingDoc(null); setLocalPath(null); loadDocs();
      }
    } catch (err) {
      const errorMsg = String(err);
      if (errorMsg.includes("CONFLICT")) {
        addToast("⚠️ Conflict detected! A copy has been created.", "error");
        setEditingDoc(null); setLocalPath(null); loadDocs();
      } else {
        addToast(`Error: ${errorMsg}`, "error");
      }
    }
  };

  // ── Auth Logic ──────────────────────────────────────────────────────────

  const loadCaptcha = async () => {
    try {
      const res = await invoke<CaptchaResponse>("get_captcha");
      setCaptcha({ token: res.token, answer: res.answer_data });
    } catch (err) {
      setRegMsg({ text: `Failed to load captcha: ${err}`, type: "error" });
    }
  };

  const handleRegister = async () => {
    const pwRules = checkPasswordRules(regForm.password);
    if (!regForm.username || !regForm.email || !regForm.password || !regForm.dateOfBirth) {
      setRegMsg({ text: "All fields including date of birth are required", type: "error" }); return;
    }
    if (!allRulesPass(pwRules)) {
      setRegMsg({ text: "Password does not meet all requirements", type: "error" }); return;
    }
    if (regForm.password !== regForm.confirm) {
      setRegMsg({ text: "Passwords don't match", type: "error" }); return;
    }
    const age = getAge(regForm.dateOfBirth);
    if (age < 13) {
      setRegMsg({ text: "You must be at least 13 years old to register", type: "error" }); return;
    }
    if (!captcha || !regForm.code) {
      setRegMsg({ text: "Please enter the captcha verification code", type: "error" }); return;
    }
    setRegLoading(true); setRegMsg(null);
    try {
      const result = await invoke<RegisterResponse>("register_account", {
        nickname:        regForm.username,
        email:           regForm.email,
        password:        regForm.password,
        dateOfBirth:     regForm.dateOfBirth,
        captchaToken:    captcha.token,
        captchaSolution: regForm.code,
      });
      if (result.success && result.user_id) {
        setRegUserId(result.user_id);
        setRegMsg({ text: result.message, type: "success" });
        setRegStep(3);
      } else {
        setRegMsg({ text: "Registration failed.", type: "error" });
      }
    } catch (err) {
      setRegMsg({ text: `${err}`, type: "error" });
    } finally { setRegLoading(false); }
  };

  const handleVerifyEmail = async () => {
    if (!regUserId || !regForm.code) return;
    setRegLoading(true);
    try {
      const res = await invoke<GenericResponse>("verify_email", { userId: regUserId, code: regForm.code });
      addToast(res.message, "success");
      setAuthMode("login"); setRegStep(2);
      setRegForm({ username: "", email: "", password: "", confirm: "", code: "", dateOfBirth: "" });
    } catch (err) {
      addToast(`${err}`, "error");
    } finally { setRegLoading(false); }
  };

  const handleResendOtp = async () => {
    if (!regUserId) return;
    try {
      const res = await invoke<GenericResponse>("resend_otp", { userId: regUserId });
      addToast(res.message, "info");
    } catch (err) { addToast(`${err}`, "error"); }
  };

  const handleLogin = async () => {
    if (!loginForm.identifier || !loginForm.password) return;
    setLoginLoading(true); setLoginMsg(null);
    try {
      const result = await invoke<LoginResponse>("login", {
        identifier: loginForm.identifier,
        password:   loginForm.password,
      });
      if (result.success && result.did) {
        setDid(result.did);
        setView("dashboard");
        loadDocs();
        loadSyncStatus();
        try { await invoke("sync_now"); } catch (_) {}
        addToast("✅ Welcome back!", "success");
      } else {
        setLoginMsg({ text: "Invalid credentials.", type: "error" });
      }
    } catch (err) {
      setLoginMsg({ text: `${err}`, type: "error" });
    } finally { setLoginLoading(false); }
  };

  const handleForgotPassword = async () => {
    if (!resetEmail) return;
    setRegLoading(true); setResetMsg(null);
    try {
      const res = await invoke<GenericResponse>("forgot_password", { email: resetEmail });
      setResetMsg({ text: res.message, type: "success" });
      setResetStep(2);
    } catch (err) {
      setResetMsg({ text: `${err}`, type: "error" });
    } finally { setRegLoading(false); }
  };

  const handleResetPassword = async () => {
    if (!resetForm.token || !resetForm.password) return;
    const pwRules = checkPasswordRules(resetForm.password);
    if (!allRulesPass(pwRules)) {
      setResetMsg({ text: "Password does not meet all requirements", type: "error" }); return;
    }
    if (resetForm.password !== resetForm.confirm) {
      setResetMsg({ text: "Passwords do not match", type: "error" }); return;
    }
    setRegLoading(true); setResetMsg(null);
    try {
      const res = await invoke<GenericResponse>("reset_password", {
        userId:   resetForm.userId,
        token:    resetForm.token,
        password: resetForm.password,
        confirm:  resetForm.confirm,
      });
      addToast(res.message, "success");
      setResetStep(1); setAuthMode("login");
    } catch (err) {
      setResetMsg({ text: `${err}`, type: "error" });
    } finally { setRegLoading(false); }
  };

  // Docs sorted newest first, show last 10
  const sortedDocs = [...docs].sort((a, b) =>
    new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime()
  );
  const displayDocs = sortedDocs.slice(0, 10);
  const pending = docs.filter(d => d.is_synced === 0 && d.status !== "failed");
  const failed  = docs.filter(d => d.status === "failed");

  // ── Render ───────────────────────────────────────────────────────────────

  if (view === "boot") return (
    <>
      <style>{css}</style>
      <div className="fullscreen" style={{ alignItems: 'center' }}>
        <div style={{ textAlign: "center" }}>
          <div className="boot-logo">PRZMA</div>
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
      <div className="fullscreen" style={{ alignItems: 'center' }}>
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 56, marginBottom: 20 }}>⚠</div>
          <div style={{ fontSize: 28, marginBottom: 16, fontWeight: 600 }}>System Error</div>
          <div style={{ marginBottom: 32, color: "#8b949e" }}>Failed to initialize application</div>
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
          <div className="auth-title">PRZMA</div>
          <p className="auth-sub">Decentralized Identity System</p>

          {authMode === "forgot" && resetStep === 2 ? (
            <div>
              <h3 style={{ marginBottom: 20, color: "#F0F4F8", textAlign: 'center' }}>Set New Password</h3>
              {resetMsg && <div className={`alert alert-${resetMsg.type}`}>{resetMsg.text}</div>}
              
              <div className="input-group">
                <input
                  className="input"
                  type={showResetPw ? "text" : "password"}
                  placeholder="New Password (min. 12 characters)"
                  value={resetForm.password}
                  onChange={e => setResetForm({ ...resetForm, password: e.target.value })}
                />
                <button className="input-icon-btn" onClick={() => setShowResetPw(!showResetPw)}>
                  {showResetPw ? <EyeClosedIcon /> : <EyeOpenIcon />}
                </button>
              </div>
              
              <PasswordRules password={resetForm.password} />
              
              <div className="input-group">
                <input
                  className="input"
                  type={showResetPw ? "text" : "password"}
                  placeholder="Confirm New Password"
                  value={resetForm.confirm}
                  onChange={e => setResetForm({ ...resetForm, confirm: e.target.value })}
                />
              </div>

              <button
                className="btn"
                onClick={handleResetPassword}
                disabled={regLoading || !allRulesPass(checkPasswordRules(resetForm.password))}
                style={{ width: "100%", marginTop: 12 }}
              >
                {regLoading ? "⊙ Resetting..." : "✦ Reset Password"}
              </button>
              <button
                className="btn btn-secondary"
                onClick={() => { setResetStep(1); setAuthMode("login"); }}
                style={{ width: "100%", marginTop: 10 }}
              >
                ← Back to Login
              </button>
            </div>
          ) : (
            <>
              <div className="auth-tabs">
                <button
                  className={`auth-tab ${authMode === "register" ? "active" : ""}`}
                  onClick={() => { setAuthMode("register"); setRegMsg(null); setLoginMsg(null); setRegStep(2); }}
                >✦ Create Account</button>
                <button
                  className={`auth-tab ${authMode === "login" || authMode === "forgot" ? "active" : ""}`}
                  onClick={() => { setAuthMode("login"); setRegMsg(null); setLoginMsg(null); }}
                >⊙ Sign In</button>
              </div>

              {authMode === "register" && (
                <div>
                  {regMsg && <div className={`alert alert-${regMsg.type}`}>{regMsg.text}</div>}

                  {regStep === 2 && (
                    <div>
                      <div className="captcha-box">
                        {captcha ? (
                          <>
                            <div className="captcha-label">Enter this verification code below</div>
                            <div className="captcha-code">{captcha.answer}</div>
                          </>
                        ) : (
                          <div style={{ color: '#8b949e', fontSize: '13px' }}>
                            ⊙ Loading security check...
                          </div>
                        )}
                      </div>

                      <div className="input-group">
                        <input
                          className="input"
                          placeholder="Username (3–30 chars)"
                          value={regForm.username}
                          onChange={e => setRegForm({ ...regForm, username: e.target.value })}
                        />
                      </div>
                      
                      <div className="input-group">
                        <input
                          className="input"
                          placeholder="Email address"
                          type="email"
                          value={regForm.email}
                          onChange={e => setRegForm({ ...regForm, email: e.target.value })}
                        />
                      </div>

                      <label className="field-label">Date of Birth (must be 13+)</label>
                      <div className="dob-row">
                        <div className="input-group">
                          <input
                            className={`input ${
                              regForm.dateOfBirth
                                ? getAge(regForm.dateOfBirth) >= 13 ? "input-ok" : "input-error"
                                : ""
                            }`}
                            type="date"
                            value={regForm.dateOfBirth}
                            max={new Date().toISOString().split("T")[0]}
                            onChange={e => setRegForm({ ...regForm, dateOfBirth: e.target.value })}
                          />
                        </div>
                        {regForm.dateOfBirth && (
                          <div className={`age-badge ${getAge(regForm.dateOfBirth) >= 13 ? "ok" : "err"}`}>
                            {getAge(regForm.dateOfBirth) >= 13
                              ? `${getAge(regForm.dateOfBirth)}y ✓`
                              : `${getAge(regForm.dateOfBirth)}y ✗`}
                          </div>
                        )}
                      </div>

                      <div className="input-group">
                        <input
                          className="input"
                          placeholder="Password"
                          type={showRegPw ? "text" : "password"}
                          value={regForm.password}
                          onChange={e => setRegForm({ ...regForm, password: e.target.value })}
                        />
                        <button className="input-icon-btn" onClick={() => setShowRegPw(!showRegPw)}>
                            {showRegPw ? <EyeClosedIcon /> : <EyeOpenIcon />}
                        </button>
                      </div>
                      <PasswordRules password={regForm.password} />

                      <div className="input-group">
                        <input
                          className={`input ${
                            regForm.confirm && regForm.password
                              ? regForm.confirm === regForm.password ? "input-ok" : "input-error"
                              : ""
                          }`}
                          placeholder="Confirm Password"
                          type={showRegConfirmPw ? "text" : "password"}
                          value={regForm.confirm}
                          onChange={e => setRegForm({ ...regForm, confirm: e.target.value })}
                        />
                        <button className="input-icon-btn" onClick={() => setShowRegConfirmPw(!showRegConfirmPw)}>
                            {showRegConfirmPw ? <EyeClosedIcon /> : <EyeOpenIcon />}
                        </button>
                      </div>

                      <div className="input-group">
                        <input
                          className="input"
                          placeholder="Enter Captcha Code shown above"
                          value={regForm.code}
                          onChange={e => setRegForm({ ...regForm, code: e.target.value })}
                        />
                      </div>

                      <div className="btn-group">
                        <button
                          className="btn"
                          onClick={handleRegister}
                          disabled={
                            regLoading ||
                            !allRulesPass(checkPasswordRules(regForm.password)) ||
                            getAge(regForm.dateOfBirth) < 13
                          }
                        >
                          {regLoading ? "⊙ Creating..." : "✦ Create Account"}
                        </button>
                        <button className="btn btn-secondary" onClick={loadCaptcha} disabled={regLoading}>
                          ↺ Code
                        </button>
                      </div>
                    </div>
                  )}

                  {regStep === 3 && (
                    <div>
                      <h3 style={{ marginBottom: 20, color: "#F0F4F8", textAlign: 'center' }}>Verify Email</h3>
                      <p style={{ color: "#8b949e", marginBottom: 20, textAlign: 'center' }}>
                        Enter the 6-digit code sent to your email address.
                      </p>
                      <div className="input-group">
                        <input
                          className="input"
                          placeholder="6-Digit Code"
                          value={regForm.code}
                          onChange={e => setRegForm({ ...regForm, code: e.target.value })}
                        />
                      </div>
                      <button className="btn" onClick={handleVerifyEmail} disabled={regLoading} style={{ width: "100%" }}>
                        {regLoading ? "⊙ Verifying..." : "✦ Verify Email"}
                      </button>
                      <button className="btn btn-secondary" onClick={handleResendOtp} style={{ width: "100%", marginTop: 10 }}>
                        Resend Code
                      </button>
                    </div>
                  )}
                </div>
              )}

              {authMode === "login" && (
                <div>
                  {loginMsg && <div className={`alert alert-${loginMsg.type}`}>{loginMsg.text}</div>}
                  <div className="input-group">
                    <input
                      className="input"
                      placeholder="Username or Email"
                      value={loginForm.identifier}
                      onChange={e => setLoginForm({ ...loginForm, identifier: e.target.value })}
                    />
                  </div>
                  
                  <div className="input-group">
                    <input
                      className="input"
                      placeholder="Password"
                      type={showLoginPw ? "text" : "password"}
                      value={loginForm.password}
                      onChange={e => setLoginForm({ ...loginForm, password: e.target.value })}
                    />
                    <button className="input-icon-btn" onClick={() => setShowLoginPw(!showLoginPw)}>
                        {showLoginPw ? <EyeClosedIcon /> : <EyeOpenIcon />}
                    </button>
                  </div>

                  <button className="btn" onClick={handleLogin} disabled={loginLoading} style={{ width: "100%" }}>
                    {loginLoading ? "⊙ Signing in..." : "⊙ Sign In"}
                  </button>
                  <div style={{ textAlign: "center", marginTop: 20 }}>
                    <a href="#" onClick={e => { e.preventDefault(); setAuthMode("forgot"); setResetMsg(null); setResetStep(1); }} style={{ color: "#4A9EFF", fontSize: 13 }}>
                      Forgot Password?
                    </a>
                  </div>
                </div>
              )}

              {authMode === "forgot" && resetStep === 1 && (
                <div>
                  <h3 style={{ marginBottom: 20, color: "#F0F4F8", textAlign: 'center' }}>Forgot Password</h3>
                  {resetMsg && <div className={`alert alert-${resetMsg.type}`}>{resetMsg.text}</div>}
                  <p style={{ color: "#8b949e", marginBottom: 20, fontSize: 13, textAlign: 'center' }}>
                    Enter your email and we'll send a reset link.
                  </p>
                  <div className="input-group">
                    <input
                      className="input"
                      placeholder="Email address"
                      value={resetEmail}
                      onChange={e => setResetEmail(e.target.value)}
                    />
                  </div>
                  <button className="btn" onClick={handleForgotPassword} disabled={regLoading} style={{ width: "100%" }}>
                    {regLoading ? "⊙ Sending..." : "Send Reset Link"}
                  </button>
                  <button className="btn btn-secondary" onClick={() => setAuthMode("login")} style={{ width: "100%", marginTop: 10 }}>
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

  // ── Dashboard ──────────────────────────────────────────────────────────────
  return (
    <>
      <style>{css}</style>
      <div className="app">
        <header className="header">
          <div className="logo">PRZMA</div>
          <div className="header-right">
            <div>
              <span className={`sync-dot ${isOnline ? "online" : "offline"}`} />
              {isOnline ? "CONNECTED" : "OFFLINE"}
            </div>
            <div style={{ maxWidth: 200, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", fontFamily: "'JetBrains Mono',monospace", fontSize: 11 }}>
              {did}
            </div>
            <button className="btn btn-danger" onClick={handleLogout} style={{ padding: "6px 16px", fontSize: 12 }}>
              Logout
            </button>
          </div>
        </header>

        <nav className="sidebar">
          {[
            { id: "docs"     as const, label: "◉ Documents",    badge: null },
            { id: "create"   as const, label: "⊕ New Document", badge: null },
            { id: "sync"     as const, label: "⟲ Sync",         badge: pending.length || null },
            { id: "identity" as const, label: "⬢ Identity",     badge: null },
          ].map(n => (
            <div
              key={n.id}
              className={`nav-item ${tab === n.id ? "active" : ""}`}
              onClick={() => { setTab(n.id); setEditingDoc(null); setLocalPath(null); }}
            >
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
            <div className="status-item" style={{ marginLeft: "auto", fontSize: 11, color: "#8b949e" }}>
              Showing last 10 files
            </div>
          </div>

          <div className="panel">

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
                          onChange={e => setEditingDoc({ ...editingDoc, text_content: e.target.value })}
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
                          <p style={{ color: "#8b949e", marginBottom: "20px", fontSize: "13px" }}>
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
                            <button className="btn" onClick={handleBinaryEdit}>📂 Open File</button>
                            <button className="btn btn-success" onClick={handleBinarySave} disabled={!localPath}>⬆️ Upload Update</button>
                            <button className="btn btn-secondary" onClick={() => setEditingDoc(null)}>✖ Cancel</button>
                          </div>
                          {localPath && <p style={{ fontSize: "11px", color: "#666", marginTop: "15px" }}>Local cache: {localPath}</p>}
                        </div>
                      </div>
                    )}
                  </>
                ) : (
                  <>
                    <div className="panel-title">Documents</div>
                    <div className="panel-sub">
                      {docs.length} total · {syncStatus.synced} synced · showing last {Math.min(10, docs.length)} (newest first)
                    </div>
                    {displayDocs.length === 0 ? (
                      <div className="empty">
                        <div className="empty-icon">◉</div>
                        <div style={{ fontSize: 16, marginBottom: 8 }}>No documents yet</div>
                        <div style={{ fontSize: 13 }}>Create your first document to get started</div>
                      </div>
                    ) : (
                      <div className="doc-list">
                        {displayDocs.map((d, idx) => (
                          <div key={d.id} className={`doc-item ${idx === 0 ? "latest-item" : ""}`}>
                            <div className="doc-info">
                              <div className="doc-name">
                                {d.filename}
                                {d.conflict_copy_of && <span className="doc-conflict">(Conflict Copy)</span>}
                              </div>
                              <div className="doc-meta">
                                {new Date(d.updated_at).toLocaleString()} · {d.content_type || 'text/plain'}
                              </div>
                            </div>
                            <div className="doc-status">
                              {idx === 0 && <span className="tag tag-latest">#1 Latest</span>}
                              <span className={`tag ${d.is_synced === 1 ? "tag-synced" : d.status === "failed" ? "tag-failed" : "tag-pending"}`}>
                                {d.is_synced === 1 ? "synced" : d.status}
                              </span>
                              <span className="version-tag">v{d.version}</span>
                              <button className="btn" onClick={() => setEditingDoc(d)} style={{ padding: "6px 14px", fontSize: 12 }}>Edit</button>
                              <button className="btn btn-danger" onClick={() => delDoc(d.id)} style={{ padding: "6px 14px", fontSize: 12 }}>Delete</button>
                            </div>
                          </div>
                        ))}
                        {docs.length > 10 && (
                          <div style={{ textAlign: "center", color: "#8b949e", fontSize: 13, padding: "12px" }}>
                            +{docs.length - 10} older files hidden · use search to find them
                          </div>
                        )}
                      </div>
                    )}
                  </>
                )}
              </>
            )}

            {/* ── Create Tab ── */}
            {tab === "create" && (
              <>
                <div className="panel-title">New Document</div>
                <div className="panel-sub">Create a local document · Automatically syncs when online</div>

                {/* Corrected Structure: Input and Button are outside the text description div */}
                <div className="card" style={{ marginBottom: "20px", borderStyle: "dashed" }}>
                  <div style={{ textAlign: "center", padding: "20px 0" }}>
                    <div style={{ fontSize: "32px", marginBottom: "10px" }}>📁</div>
                    <div style={{ fontWeight: 600, marginBottom: "10px" }}>Upload Any File</div>
                    <div style={{ fontSize: "12px", color: "#8b949e", marginBottom: "20px" }}>
                      Supports: PDF, Images, Videos, MP3, ZIP, etc.
                    </div>
                    <input type="file" id="file-upload" style={{ display: 'none' }} onChange={handleFileUpload} />
                    <button className="btn btn-success" onClick={() => document.getElementById('file-upload')?.click()}>
                      ⬆️ Select File to Upload
                    </button>
                  </div>
                </div>

                <div className="card">
                  <div style={{ fontSize: "14px", fontWeight: 600, marginBottom: "16px", color: "#8b949e" }}>
                    OR CREATE TEXT DOCUMENT
                  </div>
                  <div className="input-group">
                    <input className="input" placeholder="Filename (e.g., project-notes.txt)" value={newDoc.filename} onChange={e => setNewDoc({ ...newDoc, filename: e.target.value })} />
                  </div>
                  <textarea className="input" placeholder="Document content..." rows={8} value={newDoc.content} onChange={e => setNewDoc({ ...newDoc, content: e.target.value })} style={{marginBottom: '16px'}} />
                  <div className="input-group">
                    <input className="input" placeholder="Tags (comma separated)" value={newDoc.tags} onChange={e => setNewDoc({ ...newDoc, tags: e.target.value })} />
                  </div>
                  <button className="btn" onClick={createDoc} style={{ width: "100%" }}>⊕ Create Text Document</button>
                </div>
              </>
            )}

            {tab === "sync" && (
              <>
                <div className="panel-title">Sync Engine</div>
                <div className="panel-sub">Background synchronization · Offline queue · Auto-retry on failure</div>
                <div className="card">
                  <div style={{ marginBottom: 20, display: "flex", alignItems: "center", gap: 12 }}>
                    <div className={`sync-dot ${isOnline ? "online" : "offline"}`} />
                    <span style={{ fontWeight: 600 }}>{isOnline ? "Connected to server" : "Offline mode"}</span>
                  </div>
                  <button
                    className="btn"
                    onClick={syncNow}
                    disabled={!isOnline || syncStatus.pending === 0}
                    style={{ width: "100%" }}
                  >
                    {isOnline
                      ? syncStatus.pending > 0 ? `⟲ Sync ${syncStatus.pending} Document(s)` : "✓ Everything Synced"
                      : "⚠ Offline — Waiting for connection"}
                  </button>
                </div>

                {pending.length > 0 && (
                  <div style={{ border: "1px solid rgba(255,184,0,0.3)", padding: 20, background: "rgba(255,184,0,0.05)", marginBottom: 20, borderRadius: 12 }}>
                    <div style={{ fontWeight: 600, marginBottom: 12, color: "#FFB800" }}>⏳ Pending Upload</div>
                    {pending.map(d => <div key={d.id} style={{ fontSize: 13, marginBottom: 4, fontFamily: "'JetBrains Mono',monospace" }}>• {d.filename}</div>)}
                  </div>
                )}

                {failed.length > 0 && (
                  <div style={{ border: "1px solid rgba(255,107,107,0.3)", padding: 20, background: "rgba(255,107,107,0.05)", borderRadius: 12 }}>
                    <div style={{ fontWeight: 600, marginBottom: 12, color: "#FF6B6B" }}>✗ Failed Uploads</div>
                    {failed.map(d => <div key={d.id} style={{ fontSize: 13, marginBottom: 4, color: "#FF6B6B", fontFamily: "'JetBrains Mono',monospace" }}>• {d.filename}</div>)}
                    <button className="btn btn-danger" onClick={syncNow} style={{ marginTop: 16 }}>↺ Retry Failed</button>
                  </div>
                )}
              </>
            )}

            {tab === "identity" && (
              <>
                <div className="panel-title">Identity</div>
                <div className="panel-sub">Decentralized identifier · Cryptographically verified</div>
                <div className="card">
                  <span className="label">Your DID</span>
                  <div className="did-box">{did}</div>
                  <div className="divider" />
                  <div style={{ fontSize: 13, color: "#8b949e", lineHeight: 2 }}>
                    {/* <div><strong style={{ color: "#F0F4F8" }}>Method:</strong>  did:przma</div>
                    <div><strong style={{ color: "#F0F4F8" }}>Format:</strong>  Base64URL SHA-256</div>
                    <div><strong style={{ color: "#F0F4F8" }}>Type:</strong>    Decentralized Identifier</div> */}
                    <div><strong style={{ color: "#F0F4F8" }}>Status:</strong>  Active</div>
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
