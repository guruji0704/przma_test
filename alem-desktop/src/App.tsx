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
  tags?: string[];
}

interface Toast {
  id: number;
  msg: string;
  type: "info" | "success" | "error";
}

// ── Doc Action Icons ───────────────────────────────────────────────────────
const IconView = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" /><circle cx="12" cy="12" r="3" />
  </svg>
);
const IconEdit = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" /><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
  </svg>
);
const IconDownload = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><polyline points="7 10 12 15 17 10" /><line x1="12" y1="15" x2="12" y2="3" />
  </svg>
);
const IconDelete = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <polyline points="3 6 5 6 21 6" /><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" /><path d="M10 11v6" /><path d="M14 11v6" /><path d="M9 6V4h6v2" />
  </svg>
);

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
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap');

  * { margin: 0; padding: 0; box-sizing: border-box; }

  @keyframes orb-a {
    0%   { transform: translate(0px,   0px)   scale(1);    }
    25%  { transform: translate(40px, -60px)  scale(1.1);  }
    50%  { transform: translate(-30px, 50px)  scale(0.92); }
    75%  { transform: translate(60px,  30px)  scale(1.06); }
    100% { transform: translate(0px,   0px)   scale(1);    }
  }
  @keyframes orb-b {
    0%   { transform: translate(0px,  0px)   scale(1);    }
    25%  { transform: translate(-50px, 40px) scale(1.08); }
    50%  { transform: translate(60px, -30px) scale(0.94); }
    75%  { transform: translate(-20px,-60px) scale(1.05); }
    100% { transform: translate(0px,  0px)   scale(1);    }
  }
  @keyframes orb-c {
    0%   { transform: translate(0px,  0px)  scale(1);    }
    33%  { transform: translate(30px, 50px) scale(1.07); }
    66%  { transform: translate(-60px,-20px)scale(0.95); }
    100% { transform: translate(0px,  0px)  scale(1);    }
  }

  body, html, #root {
    height: 100%;
    background: #060810;
    color: #F0F4F8;
    font-family: 'Inter', sans-serif;
    font-size: 14px;
    line-height: 1.6;
    overflow: hidden;
  }

  /* ── Prism orb layer 1: cool tones ── */
  body::before {
    content: '';
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 0;
    background:
      radial-gradient(ellipse 70% 55% at 12% 18%,  rgba(74,  158, 255, 0.28) 0%, transparent 60%),
      radial-gradient(ellipse 55% 65% at 85% 8%,   rgba(120,  60, 255, 0.22) 0%, transparent 60%),
      radial-gradient(ellipse 60% 50% at 60% 88%,  rgba(0,  224, 198, 0.20) 0%, transparent 60%);
    animation: orb-a 20s ease-in-out infinite;
    mix-blend-mode: screen;
  }
  /* ── Prism orb layer 2: warm tones ── */
  body::after {
    content: '';
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 0;
    background:
      radial-gradient(ellipse 50% 60% at 88% 72%,  rgba(255,  80, 140, 0.18) 0%, transparent 60%),
      radial-gradient(ellipse 60% 45% at 18% 78%,  rgba(255, 184,   0, 0.16) 0%, transparent 60%),
      radial-gradient(ellipse 45% 55% at 50% 40%,  rgba(80,  200, 255, 0.14) 0%, transparent 60%);
    animation: orb-b 26s ease-in-out infinite;
    mix-blend-mode: screen;
  }

  /* ── Noise grain overlay for depth ── */
  #root {
    position: relative;
    z-index: 1;
  }
  #root::before {
    content: '';
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 2;
    opacity: 0.025;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
    background-size: 180px 180px;
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
    padding: 0 40px;
    background: rgba(6, 8, 16, 0.55);
    backdrop-filter: blur(20px);
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    z-index: 100;
  }

  .logo {
    font-size: 22px;
    font-weight: 700;
    letter-spacing: 4px;
    background: linear-gradient(135deg, #4A9EFF 0%, #FFB800 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 24px;
    font-size: 11px;
    color: #94A9C9;
  }

  .sidebar {
    border-right: 1px solid rgba(255,255,255,0.05);
    background: rgba(6, 8, 16, 0.5);
    padding: 24px 16px;
    overflow-y: auto;
    position: relative;
    z-index: 1;
  }

  .doc-action-btn {
    flex: 1; padding: 10px 8px; display: flex; align-items: center; justify-content: center;
  }

  .nav-item {
    padding: 14px 20px;
    margin-bottom: 8px;
    cursor: pointer;
    border-radius: 14px;
    transition: all 0.2s;
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.4);
  }
  .nav-item:hover { background: rgba(255, 255, 255, 0.03); color: #fff; }
  .nav-item.active { background: rgba(74, 158, 255, 0.1); color: #4A9EFF; }

  .main { overflow-y: auto; background: transparent; }

  .panel { padding: 40px; max-width: 1200px; }

  .card {
    border: 1px solid rgba(255,255,255,0.07);
    padding: 24px;
    background: rgba(6, 8, 16, 0.45);
    backdrop-filter: blur(12px);
    border-radius: 12px;
    box-shadow: 0 8px 40px rgba(0,0,0,0.35);
  }

  .doc-list { 
    display: grid; 
    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); 
    gap: 24px; 
  }

  .doc-name { font-weight:600; margin-bottom:4px; color:#F0F4F8; }
  .doc-meta { font-size:12px; color:rgba(255,255,255,0.3); font-family:'JetBrains Mono',monospace; }

  .btn {
    padding:12px 20px; border:1px solid rgba(255,255,255,0.1); background:transparent;
    color:#F0F4F8; font-size:13px; font-weight:600;
    cursor:pointer; transition:all 0.2s; border-radius:10px;
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  }
  .btn:hover { background:rgba(255,255,255,0.05); transform:translateY(-1px); }
  .btn-danger { border-color:rgba(255,107,107,0.3); color:#FF6B6B; }
  .btn-danger:hover { background:rgba(255,107,107,0.1); }

  .input-group { position: relative; margin-bottom: 20px; width: 100%; }
  .input {
    width:100%; padding:14px 18px; background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.05);
    color:#F0F4F8; font-size:14px; outline:none; border-radius:12px; transition:all 0.2s;
  }
  .input:focus { border-color:#4A9EFF; background: rgba(255,255,255,0.05); }

  .input-icon-btn {
    position: absolute; right: 12px; top: 50%; transform: translateY(-50%);
    background: transparent; border: none; padding: 4px; cursor: pointer; color: #8b949e;
  }

  .toast-container { position:fixed; bottom:24px; right:24px; display:flex; flex-direction:column; gap:12px; z-index:2000; }
  .toast {
    padding:14px 18px; border:1px solid rgba(255,255,255,0.1); background:rgba(13,17,23,0.9);
    font-size:13px; border-radius:12px; box-shadow:0 8px 32px rgba(0,0,0,0.4);
    backdrop-filter:blur(10px); color: #fff; min-width: 260px;
    animation: slideIn 0.3s cubic-bezier(0.175, 0.885, 0.32, 1.275);
  }
  @keyframes slideIn { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } }

  .fullscreen {
    height: 100vh; display: flex; align-items: center; justifyContent: center;
    background: transparent;
  }
  .auth-container {
    width: 440px; padding: 32px; background: rgba(6, 8, 16, 0.5);
    border: 1px solid rgba(255,255,255,0.08); border-radius: 24px;
    backdrop-filter: blur(24px); max-height: 95vh; overflow-y: auto;
    box-shadow: 0 24px 80px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.06);
    scrollbar-width: none; /* Firefox */
  }
  .auth-container::-webkit-scrollbar { display: none; } /* Chrome/Safari */

  .sync-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 8px; }
  .sync-dot.online  { background: #00E0C6; box-shadow: 0 0 12px rgba(0,224,198,0.5); }
  .sync-dot.offline { background: #FF6B6B; }

  .pw-rules {
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 12px;
    padding: 16px;
    margin-bottom: 20px;
  }
  .pw-rules-title {
    font-size: 11px;
    color: rgba(255, 255, 255, 0.3);
    text-transform: uppercase;
    letter-spacing: 1px;
    margin-bottom: 12px;
    font-weight: 700;
  }
  .pw-rule {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: rgba(255, 255, 255, 0.4);
    padding: 3px 0;
    transition: color 0.2s;
  }
  .pw-rule.ok { color: #00E0C6; }
  .pw-rule-icon { width: 14px; text-align: center; }
  .pw-strength-bar {
    height: 4px; border-radius: 2px;
    margin-bottom: 12px; background: rgba(255, 255, 255, 0.05);
    overflow: hidden;
  }
  .pw-strength-fill { height: 100%; transition: all 0.3s; }

  .dob-row { display: flex; gap: 12px; align-items: flex-start; margin-bottom: 20px; }
  .dob-row .input-group { flex: 1; margin-bottom: 0; }
  
  .age-badge {
    padding: 14px; border-radius: 12px; font-size: 13px; font-weight: 700;
    font-family: 'JetBrains Mono', monospace; border: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(255, 255, 255, 0.02); color: rgba(255, 255, 255, 0.3);
    min-width: 70px; text-align: center; height: 48px; display: flex; align-items: center; justify-content: center;
  }
  .age-badge.ok  { border-color: rgba(0, 224, 198, 0.2); color: #00E0C6; background: rgba(0, 224, 198, 0.05); }
  .age-badge.err { border-color: rgba(255, 107, 107, 0.2); color: #FF6B6B; background: rgba(255, 107, 107, 0.05); }

  .captcha-box {
    border: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(255, 255, 255, 0.03);
    margin-bottom: 20px; border-radius: 12px;
    padding: 16px 18px;
  }
  .captcha-img {
    width: 100%; border-radius: 8px; overflow: hidden;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.05);
    margin-bottom: 12px; padding: 12px;
    display: flex; align-items: center; justify-content: center;
  }
  .captcha-img svg, .captcha-img img { filter: invert(1) brightness(0.85); display: block; }
  
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
  const [tab, setTab] = useState<"docs" | "create">("docs");
  const [viewDoc, setViewDoc] = useState<Doc | null>(null);
  const [pendingEdit, setPendingEdit] = useState<{ id: string; localPath: string; version: number; filename: string } | null>(null);
  const [docs, setDocs] = useState<Doc[]>([]);
  const [toasts, setToasts] = useState<{ id: number, msg: string, type: string }[]>([]);
  const [isOnline, setIsOnline] = useState(navigator.onLine);

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
    try { setDocs(await invoke<Doc[]>("list_documents")); }
    catch (err) { console.error(err); }
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

  const displayDocs = docs.filter(d => d.filename.toLowerCase().includes(searchQuery.toLowerCase()));

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
        <div style={{ textAlign: 'center', marginBottom: 32 }}>
          <div className="logo" style={{ fontSize: 32 }}>PRZMA</div>
          <div style={{ fontSize: 10, opacity: 0.5, marginTop: 4, letterSpacing: 2 }}>DECENTRALIZED IDENTITY SYSTEM</div>
        </div>

        {authMode !== "forgot" && regStep !== 3 && (
          <div style={{ display: 'flex', gap: 8, marginBottom: 32, background: 'rgba(255,255,255,0.03)', padding: 4, borderRadius: 14 }}>
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
      <div className="app">
        <header className="header">
          <div className="logo">PRZMA</div>
          <div className="header-right">
            <div>
              <span className={`sync-dot ${isOnline ? "online" : "offline"}`} />
              {isOnline ? "ONLINE" : "OFFLINE"}
            </div>
            <div style={{ fontFamily: 'JetBrains Mono', fontSize: 12, opacity: 0.7 }}>{username}</div>
            <button className="btn btn-danger" onClick={handleLogout} style={{ padding: '6px 12px', fontSize: 11 }}>Logout</button>
          </div>
        </header>

        <nav className="sidebar">
          <div className={`nav-item ${tab === 'docs' ? 'active' : ''}`} onClick={() => setTab('docs')}>
            <span>◉ Library</span>
          </div>
          <div className={`nav-item ${tab === 'create' ? 'active' : ''}`} onClick={() => { setTab('create'); handleUpload(); }}>
            <span>⊕ Add File</span>
          </div>
        </nav>

        <main className="main">
          {tab === 'docs' && (
            <div className="panel">
              <div style={{ marginBottom: 40 }}>
                <div style={{ fontSize: 32, fontWeight: 800, letterSpacing: -1 }}>Vault Library</div>
                <div style={{ opacity: 0.3, fontSize: 13 }}>{docs.length} encrypted artifacts stored locally and mirrored on PRZMA nodes</div>
              </div>

              <div className="input-group" style={{ marginBottom: 48 }}>
                <input
                  className="input"
                  style={{ padding: '18px 24px', borderRadius: 20 }}
                  placeholder="Search artifacts..."
                  value={searchQuery}
                  onChange={e => setSearchQuery(e.target.value)}
                />
              </div>

              <div className="doc-list">
                {displayDocs.map(d => (
                  <div key={d.id} className="card">
                    <div className="doc-name" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                      <span>{d.filename}</span>
                      <span style={{ fontSize: 9, background: 'rgba(74, 158, 255, 0.1)', color: '#4A9EFF', padding: '2px 6px', borderRadius: 4 }}>
                        V{d.version || 1}
                      </span>
                    </div>

                    <div className="doc-meta">
                      {new Date(d.updated_at).toLocaleDateString()} · {new Date(d.updated_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                    </div>

                    <div style={{ display: 'flex', gap: 6, marginTop: 20 }}>
                      <button className="btn doc-action-btn" title="View" onClick={() => setViewDoc(d)}><IconView /></button>

                      <button className="btn doc-action-btn" title="Edit" onClick={async () => {
                        addToast("Opening file...", "info");
                        try {
                          const localPath = await invoke<string>("open_file_for_edit", { id: d.id, filename: d.filename });
                          setPendingEdit({ id: d.id, localPath, version: d.version, filename: d.filename });
                        } catch (e: any) { addToast(e, "error"); }
                      }}><IconEdit /></button>

                      <button className="btn doc-action-btn" title="Download" style={{ color: '#4A9EFF', borderColor: 'rgba(74,158,255,0.2)' }} onClick={async () => {
                        const { save } = await import("@tauri-apps/plugin-dialog");
                        const { writeFile } = await import("@tauri-apps/plugin-fs");
                        const savePath = await save({ defaultPath: d.filename });
                        if (!savePath) return;
                        addToast("Downloading...", "info");
                        try {
                          const bytes = await invoke<number[]>("get_file_bytes", { id: d.id });
                          await writeFile(savePath, new Uint8Array(bytes));
                          addToast("File saved", "success");
                        } catch (e: any) { addToast(e, "error"); }
                      }}><IconDownload /></button>

                      <button className="btn doc-action-btn btn-danger" title="Delete" onClick={() => handleDocDelete(d.id)}><IconDelete /></button>
                    </div>
                  </div>
                ))}
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
