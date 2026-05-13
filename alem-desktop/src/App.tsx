import { useState, useEffect, useMemo, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ask } from "@tauri-apps/plugin-dialog";
import { tableFromIPC } from "apache-arrow";
import { Socket, Channel } from "phoenix";

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


interface ChatRoom {
  id: string;
  name: string;
  vault: string;
  owner_user_id: string;
  description?: string;
  is_dm: boolean;
  dm_user_ids?: string[];
  partner_user_id?: string;
  partner_username?: string;
  is_member?: boolean;
  is_owner?: boolean;
  max_members?: number;
  member_count?: number;
  is_full?: boolean;
  mode?: 'member' | 'audience';
  inserted_at?: string;
}

interface ChatMessage {
  id: string;
  room_id: string;
  vault: string;
  user_id: string;
  username: string;
  body?: string;
  msg_type: string;
  file_doc_id?: string;
  file_name?: string;
  file_type?: string;
  inserted_at?: string;
}

interface RoomMember {
  user_id:  string;
  username: string;
  role:     string;
  online?:  boolean;
  joined_at?: string;
}

interface PrzmaUser {
  id:       string;
  nickname: string;
  name:     string;
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
const IconShare = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/></svg>;

const Thumbnail = ({ type, filename, id, preloadedSrc }: { type: string, filename: string, id?: string, vaultName: string, preloadedSrc?: string }) => {
  const [src, setSrc] = useState<string | null>(null);
  const ct = type.toLowerCase();
  const isImage = ct.startsWith("image/");
  
  useEffect(() => {
    if (preloadedSrc) {
      setSrc(`data:image/png;base64,${preloadedSrc}`);
      return;
    }
    if (isImage && id) {
      invoke<string | null>("get_thumbnail", { docId: id })
        .then(b64 => {
          if (b64) {
            setSrc(`data:image/png;base64,${b64}`);
          }
        })
        .catch(console.error);
    }
  }, [id, isImage, preloadedSrc]);

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

  /* ── PRISM (default) — deep space / aurora spectrum ─── */
  :root, [data-theme='prism'] {
    --bg-primary: #02030C;
    --bg-secondary: #05071A;
    --bg-header: rgba(2, 3, 12, 0.88);
    --text-primary: #EBF0FF;
    --text-secondary: rgba(160, 180, 255, 0.68);
    --border: rgba(100, 110, 255, 0.10);
    --accent: #7C9EFF;
    --accent-glow: rgba(124, 158, 255, 0.13);
    --card-shadow: 0 10px 48px rgba(0, 0, 24, 0.65);
  }

  /* ── DARK — premium charcoal / GitHub-inspired ──────── */
  [data-theme='dark'] {
    --bg-primary: #0D1117;
    --bg-secondary: #161B22;
    --bg-header: rgba(13, 17, 23, 0.92);
    --text-primary: #E6EDF3;
    --text-secondary: #848D97;
    --border: #2D333B;
    --accent: #4D9BFF;
    --accent-glow: rgba(77, 155, 255, 0.14);
    --card-shadow: 0 8px 32px rgba(0, 0, 0, 0.55);
  }

  /* ── LIGHT — warm minimal / Notion-inspired ─────────── */
  [data-theme='light'] {
    --bg-primary: #FAFBFD;
    --bg-secondary: #EEF2F8;
    --bg-header: rgba(250, 251, 253, 0.95);
    --text-primary: #0F172A;
    --text-secondary: #5E6E8A;
    --border: #D4DCEA;
    --accent: #3B6EF0;
    --accent-glow: rgba(59, 110, 240, 0.09);
    --card-shadow: 0 2px 14px rgba(15, 23, 42, 0.07);
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
    transition: opacity 1.4s ease;
    pointer-events: none;
  }
  [data-theme='prism'] .prism-bg { opacity: 1; }

  .prism-orb {
    position: absolute;
    border-radius: 50%;
    filter: blur(130px);
    mix-blend-mode: screen;
  }
  .prism-orb-1 {
    width: 720px; height: 720px;
    animation: orb1 26s ease-in-out infinite alternate;
  }
  .prism-orb-2 {
    width: 560px; height: 560px;
    animation: orb2 34s ease-in-out infinite alternate;
  }
  .prism-orb-3 {
    width: 440px; height: 440px;
    animation: orb3 22s ease-in-out infinite alternate;
  }
  .prism-orb-4 {
    width: 320px; height: 320px;
    animation: orb4 18s ease-in-out infinite alternate;
  }

  @keyframes orb1 {
    0%   { transform: translate(-15%, -20%); }
    100% { transform: translate(25%, 35%); }
  }
  @keyframes orb2 {
    0%   { transform: translate(85%, 60%); }
    100% { transform: translate(30%, -10%); }
  }
  @keyframes orb3 {
    0%   { transform: translate(40%, 35%); }
    100% { transform: translate(-5%, 65%); }
  }
  @keyframes orb4 {
    0%   { transform: translate(60%, -5%); }
    100% { transform: translate(15%, 55%); }
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
    transition: all 0.3s cubic-bezier(0.175, 0.885, 0.32, 1);
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .nav-item:hover { background: rgba(255,255,255,0.05); color: var(--text-primary); }
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
    background: rgba(255, 255, 255, 0.028);
    border: 1px solid rgba(255, 255, 255, 0.055);
    border-radius: 20px;
    padding: 24px;
    transition: all 0.35s cubic-bezier(0.175, 0.885, 0.32, 1);
    backdrop-filter: blur(20px) saturate(140%);
    position: relative;
    overflow: hidden;
  }
  .card:hover {
    transform: translateY(-3px);
    border-color: rgba(124, 158, 255, 0.18);
    box-shadow: 0 16px 48px rgba(0, 0, 20, 0.5), inset 0 1px 0 rgba(124, 158, 255, 0.08);
  }
  [data-theme='dark'] .card {
    background: rgba(255, 255, 255, 0.025);
    border-color: rgba(255, 255, 255, 0.05);
  }
  [data-theme='dark'] .card:hover {
    border-color: rgba(77, 155, 255, 0.2);
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.45), inset 0 1px 0 rgba(77, 155, 255, 0.06);
  }
  [data-theme='light'] .card {
    background: rgba(255, 255, 255, 0.85);
    border-color: rgba(15, 23, 42, 0.07);
    backdrop-filter: blur(12px);
  }
  [data-theme='light'] .card:hover {
    border-color: rgba(59, 110, 240, 0.22);
    box-shadow: 0 8px 28px rgba(15, 23, 42, 0.10), inset 0 1px 0 rgba(59, 110, 240, 0.05);
    transform: translateY(-2px);
  }
  .sort-bar {
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
    background: rgba(255,255,255,0.03);
    border: 1px solid rgba(255,255,255,0.06);
    color: var(--text-primary);
    padding: 16px 20px;
    border-radius: 16px;
    width: 100%;
    outline: none;
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    font-size: 15px;
  }
  .input::placeholder { color: rgba(255,255,255,0.2); }
  .input:hover { background: rgba(255,255,255,0.05); border-color: rgba(255,255,255,0.15); }
  .input:focus { 
    background: rgba(255,255,255,0.06); 
    border-color: var(--accent); 
    box-shadow: 0 0 0 4px var(--accent-glow); 
    transform: translateY(-1px);
  }

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
    background: rgba(10, 13, 20, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.08);
    backdrop-filter: blur(40px) saturate(150%);
    border-radius: 32px;
    padding: 56px 48px;
    box-shadow: 0 24px 64px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.1);
  }
  [data-theme='light'] .auth-container { background: rgba(255, 255, 255, 0.92); box-shadow: 0 16px 48px rgba(15,23,42,0.1); }
  [data-theme='light'] .sidebar { background: #EEF2F8; }
  [data-theme='light'] .chat-sidebar { background: #EEF2F8; }
  [data-theme='light'] .nav-item:hover { background: rgba(59,110,240,0.07); }
  [data-theme='light'] .room-item:hover { background: rgba(59,110,240,0.07); }
  [data-theme='light'] .chat-textarea { background: rgba(0,0,0,0.03); border-color: #D4DCEA; color: #0F172A; }
  [data-theme='light'] .chat-textarea:focus { background: rgba(0,0,0,0.04); border-color: var(--accent); }
  [data-theme='light'] .msg-body { background: rgba(0,0,0,0.04); color: #0F172A; }
  [data-theme='light'] .msg-body.own { background: rgba(59,110,240,0.10); border-color: rgba(59,110,240,0.18); }

  .auth-scroll-area {
    max-height: 50vh;
    min-height: 300px;
    overflow-y: auto;
    padding-right: 12px;
    margin-right: -12px;
    scrollbar-width: thin;
    scrollbar-color: var(--border) transparent;
  }
  .auth-scroll-area::-webkit-scrollbar { width: 4px; }
  .auth-scroll-area::-webkit-scrollbar-track { background: transparent; }
  .auth-scroll-area::-webkit-scrollbar-thumb { background: var(--border); border-radius: 10px; }

  .btn {
    padding: 12px 24px;
    border-radius: 14px;
    border: 1px solid rgba(255,255,255,0.06);
    background: rgba(255,255,255,0.03);
    color: var(--text-primary);
    cursor: pointer;
    font-size: 14px;
    font-weight: 600;
    letter-spacing: 0.2px;
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  }
  .btn:hover { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.15); }
  .btn:active { transform: scale(0.98); }
  .btn-accent { 
    background: linear-gradient(135deg, #4A9EFF 0%, #00E0C6 100%); 
    color: white; 
    border: none; 
    box-shadow: 0 8px 24px rgba(74, 158, 255, 0.3);
  }
  .btn-accent:hover { 
    opacity: 0.95; 
    transform: translateY(-2px); 
    box-shadow: 0 12px 28px rgba(74, 158, 255, 0.4); 
    border-color: transparent; 
  }
  .btn-danger { color: #FF6B6B; background: rgba(255,107,107,0.05); border-color: rgba(255,107,107,0.15); }
  .btn-danger:hover { background: rgba(255,107,107,0.15); border-color: rgba(255,107,107,0.3); }

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
    appearance: none;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    color: var(--text-primary);
    padding: 5px 28px 5px 10px;
    border-radius: 9px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    outline: none;
    transition: border-color 0.15s;
    background-image: url("data:image/svg+xml;charset=UTF-8,%3csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23888' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3e%3cpolyline points='6 9 12 15 18 9'%3e%3c/polyline%3e%3c/svg%3e");
    background-repeat: no-repeat;
    background-position: right 7px center;
    background-size: 13px;
  }
  .theme-select:hover { border-color: var(--accent); }
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
    padding: 16px 20px; background: rgba(0,0,0,0.3); border-radius: 14px;
    font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #4A9EFF;
    word-break: break-all; margin: 24px 0; border: 1px solid rgba(74, 158, 255, 0.15);
    box-shadow: inset 0 2px 12px rgba(0,0,0,0.5);
  }

  /* Auth alignment */
  .input-group { margin-bottom: 20px; position: relative; width: 100%; }
  .dob-row { display: flex; gap: 12px; margin-bottom: 20px; align-items: stretch; }
  .dob-row .input-group { margin-bottom: 0; flex: 1; }
  .age-badge { display: flex; align-items: center; justify-content: center; background: rgba(255,107,107,0.1); color: #FF6B6B; padding: 0 16px; border-radius: 14px; font-weight: 700; font-size: 13px; height: 50px; }
  .age-badge.ok { background: rgba(0, 224, 198, 0.1); color: #00E0C6; }
  
  .pw-rules { margin-top: 8px; margin-bottom: 24px; padding: 16px; background: rgba(0,0,0,0.2); border-radius: 14px; border: 1px solid var(--border); }
  .pw-strength-bar { height: 4px; background: rgba(255,255,255,0.1); border-radius: 2px; overflow: hidden; margin-bottom: 12px; }
  .pw-strength-fill { height: 100%; transition: all 0.3s ease; }
  .pw-rules-title { font-size: 12px; font-weight: 600; color: var(--text-primary); margin-bottom: 12px; }
  .pw-rule { font-size: 11px; color: var(--text-secondary); display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
  .pw-rule:last-child { margin-bottom: 0; }
  .pw-rule.ok { color: #00E0C6; }
  .pw-rule-icon { font-weight: bold; }
  
  .captcha-box { background: rgba(0,0,0,0.2); padding: 16px; border-radius: 14px; border: 1px solid var(--border); margin-bottom: 24px; }
  .captcha-img { height: 52px; background: white; border-radius: 8px; overflow: hidden; display: flex; align-items: center; justify-content: center; }
  .captcha-img svg { max-height: 100%; max-width: 100%; }

  /* ── Teams / Social Panel ────────────────────────────── */
  .chat-layout { display: grid; grid-template-columns: 232px 1fr; height: 100%; overflow: hidden; }

  .chat-sidebar {
    border-right: 1px solid var(--border);
    display: flex; flex-direction: column; overflow: hidden;
    background: var(--bg-secondary);
  }

  .sidebar-head {
    padding: 14px 12px 10px;
    display: flex; align-items: center; gap: 8px;
    border-bottom: 1px solid var(--border);
  }
  .sidebar-head-title { font-size: 13px; font-weight: 700; color: var(--text-primary); flex: 1; }
  .live-dot {
    width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0;
    transition: background 0.3s;
  }
  .live-dot.on  { background: #10B981; box-shadow: 0 0 6px rgba(16,185,129,0.5); }
  .live-dot.off { background: #4B5563; }

  .sidebar-actions {
    padding: 8px; display: flex; align-items: center; gap: 6px;
    border-bottom: 1px solid var(--border);
  }
  .filter-pills { display: flex; gap: 3px; flex: 1; }
  .filter-pill {
    flex: 1; padding: 4px 0; border-radius: 6px; border: 1px solid transparent;
    font-size: 10px; font-weight: 700; cursor: pointer; background: transparent;
    color: var(--text-secondary); transition: all 0.12s; text-align: center;
  }
  .filter-pill.active { border-color: var(--accent); color: var(--accent); background: var(--accent-glow); }
  .filter-pill:hover:not(.active) { color: var(--text-primary); background: rgba(255,255,255,0.04); }

  .new-room-btn {
    padding: 5px 9px; border-radius: 7px; border: 1px solid var(--border);
    background: transparent; color: var(--text-secondary); font-size: 16px; font-weight: 400;
    cursor: pointer; line-height: 1; transition: all 0.12s; flex-shrink: 0;
  }
  .new-room-btn:hover { border-color: var(--accent); color: var(--accent); background: var(--accent-glow); }

  .room-list { overflow-y: auto; padding: 4px; flex: 1; }
  .room-item {
    padding: 8px 10px; border-radius: 8px; cursor: pointer;
    display: flex; align-items: center; gap: 7px;
    font-size: 13px; font-weight: 500; color: var(--text-primary);
    transition: all 0.12s; position: relative;
  }
  .room-item:hover { background: rgba(255,255,255,0.05); }
  .room-item.active { background: var(--accent-glow); color: var(--accent); font-weight: 600; }
  .room-item .room-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
  .room-item .room-actions { margin-left: auto; display: none; gap: 2px; }
  .room-item:hover .room-actions { display: flex; }
  .room-action-btn {
    padding: 2px 5px; border-radius: 4px; border: none; background: rgba(255,255,255,0.07);
    color: var(--text-secondary); cursor: pointer; font-size: 10px; transition: all 0.1s;
  }
  .room-action-btn:hover { background: rgba(255,255,255,0.14); color: var(--text-primary); }
  .room-action-btn.danger:hover { background: rgba(255,107,107,0.18); color: #FF6B6B; }

  .join-code-row {
    padding: 8px; border-top: 1px solid var(--border); display: flex; gap: 5px;
  }
  .join-code-input {
    flex: 1; padding: 5px 9px; background: rgba(255,255,255,0.04);
    border: 1px solid var(--border); border-radius: 7px; color: var(--text-primary);
    font-size: 11px; font-family: 'JetBrains Mono', monospace; outline: none;
    transition: border 0.15s;
  }
  .join-code-input:focus { border-color: var(--accent); }
  .join-code-input::placeholder { color: var(--text-secondary); opacity: 0.55; }

  /* Right content pane */
  .chat-content-pane { display: flex; flex-direction: column; overflow: hidden; }

  .content-room-header {
    padding: 11px 18px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 10px; flex-shrink: 0;
  }

  .content-tabs-bar {
    display: flex; border-bottom: 1px solid var(--border); padding: 0 14px; flex-shrink: 0;
  }
  .content-tab {
    padding: 8px 14px; font-size: 12px; font-weight: 600; cursor: pointer;
    border: none; background: transparent; color: var(--text-secondary);
    border-bottom: 2px solid transparent; transition: all 0.12s;
  }
  .content-tab.active { color: var(--accent); border-bottom-color: var(--accent); }
  .content-tab:hover:not(.active) { color: var(--text-primary); }

  .content-body { flex: 1; overflow: hidden; display: flex; flex-direction: column; }

  .messages-list { flex: 1; overflow-y: auto; padding: 14px 18px; display: flex; flex-direction: column; gap: 1px; }

  .msg-group { margin-bottom: 10px; }
  .msg-group-header { display: flex; align-items: baseline; gap: 8px; margin-bottom: 4px; padding: 0 4px; }
  .msg-author { font-size: 13px; font-weight: 700; }
  .msg-author.own { color: #a78bfa; }
  .msg-time { font-size: 10px; color: var(--text-secondary); }
  .msg-body-wrap { padding: 0 4px; }
  .msg-body {
    font-size: 13px; line-height: 1.6; color: var(--text-primary); word-break: break-word;
    background: rgba(255,255,255,0.03); padding: 7px 11px; border-radius: 8px;
    display: inline-block; max-width: 85%;
  }
  .msg-body.own {
    background: rgba(88,166,255,0.11); border: 1px solid rgba(88,166,255,0.14);
    border-bottom-right-radius: 2px;
  }

  .msg-file-card {
    display: inline-flex; align-items: center; gap: 10px; margin-top: 4px;
    padding: 8px 12px; border-radius: 8px; border: 1px solid var(--border);
    background: rgba(255,255,255,0.03); cursor: pointer;
    transition: all 0.15s; max-width: 300px;
  }
  .msg-file-card:hover { background: rgba(255,255,255,0.07); border-color: var(--accent); }

  .chat-input-area {
    padding: 10px 16px; border-top: 1px solid var(--border); flex-shrink: 0;
    display: flex; flex-direction: column; gap: 5px;
  }
  .chat-input-row { display: flex; gap: 8px; align-items: flex-end; }
  .chat-textarea {
    flex: 1; padding: 9px 12px; background: rgba(255,255,255,0.04);
    border: 1px solid var(--border); border-radius: 10px; color: var(--text-primary);
    font-size: 13px; font-family: inherit; resize: none; outline: none;
    min-height: 38px; max-height: 120px; transition: border 0.15s;
  }
  .chat-textarea:focus { border-color: var(--accent); background: rgba(255,255,255,0.06); }
  .chat-textarea::placeholder { color: var(--text-secondary); opacity: 0.6; }
  .typing-indicator { font-size: 11px; color: var(--text-secondary); min-height: 14px; padding: 0 2px; font-style: italic; }

  .chat-empty-state {
    flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center;
    color: var(--text-secondary); gap: 10px;
  }

  .chat-file-browser { overflow-y: auto; padding: 6px; }
  .chat-file-item {
    padding: 7px 10px; border-radius: 7px;
    display: flex; align-items: center; gap: 8px;
    font-size: 12px; color: var(--text-secondary); transition: all 0.12s;
    border: 1px solid transparent;
  }
  .chat-file-item:hover { background: rgba(255,255,255,0.05); color: var(--text-primary); border-color: var(--border); }
  .chat-file-item .file-share-btn {
    margin-left: auto; opacity: 0; font-size: 10px; padding: 2px 6px;
    border-radius: 4px; border: 1px solid var(--accent); color: var(--accent);
    background: var(--accent-glow); cursor: pointer; transition: opacity 0.15s;
  }
  .chat-file-item:hover .file-share-btn { opacity: 1; }

  .member-chip {
    display: flex; align-items: center; gap: 6px; padding: 5px 8px; border-radius: 7px;
    font-size: 12px; color: var(--text-secondary); transition: background 0.12s;
  }
  .member-chip:hover { background: rgba(255,255,255,0.04); }
  .member-chip .member-avatar {
    width: 22px; height: 22px; border-radius: 50%; display: flex; align-items: center;
    justify-content: center; font-size: 11px; font-weight: 700; flex-shrink: 0;
  }
  .member-chip .role-badge {
    font-size: 9px; font-weight: 800; padding: 1px 5px; border-radius: 4px; letter-spacing: 0.3px;
  }

  .invite-modal-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.75); z-index: 800;
    display: flex; align-items: center; justify-content: center; padding: 16px;
  }
  .invite-modal {
    width: 100%; max-width: 420px; background: var(--bg-secondary);
    border: 1px solid var(--border); border-radius: 16px; padding: 0; overflow: hidden;
    box-shadow: 0 24px 64px rgba(0,0,0,0.5);
  }
  .invite-modal-header {
    padding: 16px 20px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; justify-content: space-between;
  }
  .user-pick-item {
    display: flex; align-items: center; gap: 10px; padding: 9px 16px;
    cursor: pointer; transition: background 0.12s; border-bottom: 1px solid rgba(255,255,255,0.03);
  }
  .user-pick-item:hover { background: rgba(255,255,255,0.04); }
  .user-pick-item:last-child { border-bottom: none; }
  .user-avatar {
    width: 32px; height: 32px; border-radius: 50%; display: flex; align-items: center;
    justify-content: center; font-size: 14px; font-weight: 700; flex-shrink: 0;
    background: linear-gradient(135deg, #4A9EFF22 0%, #00E0C622 100%);
    border: 1px solid rgba(255,255,255,0.1);
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
  const [curPanel, setCurPanel] = useState<'personal' | 'teams' | 'social'>('personal');
  const activeVault = curPanel === 'personal' ? 'personal_vault' : curPanel === 'teams' ? 'private_vault' : 'social_vault';
  const [theme, setTheme] = useState<'prism'|'dark'|'light'>('prism');
  const [sortBy, setSortBy] = useState<'date'|'name'|'size'>('date');

  const [viewDoc, setViewDoc] = useState<Doc | null>(null);
  const [pendingEdit, setPendingEdit] = useState<{ id: string; localPath: string; version: number; filename: string } | null>(null);
  const [shareModal, setShareModal] = useState<{ doc: Doc } | null>(null);
  const [shareLoading, setShareLoading] = useState(false);
  const [shareUsers, setShareUsers] = useState<PrzmaUser[]>([]);
  const [shareUserSearch, setShareUserSearch] = useState('');
  const [incomingShares, setIncomingShares] = useState<any[]>([]);
  const [showSharedPanel, setShowSharedPanel] = useState(false);

  // ── Chat state ──────────────────────────────────────────────────
  const chatVault = curPanel === 'teams' ? 'private' : 'social';
  const [joinCodeInput, setJoinCodeInput] = useState('');
  const [roomsTab, setRoomsTab] = useState<'all' | 'mine' | 'joined'>('all');
  const [chatRooms, setChatRooms] = useState<ChatRoom[]>([]);
  const [activeRoom, setActiveRoom] = useState<ChatRoom | null>(null);
  const [chatMessages, setChatMessages] = useState<ChatMessage[]>([]);
  const [chatInput, setChatInput] = useState('');
  const [chatTyping, setChatTyping] = useState<string[]>([]);
  const [chatConnected, setChatConnected] = useState(false);
  const [showNewRoomModal, setShowNewRoomModal] = useState(false);
  const [newRoomName, setNewRoomName] = useState('');
  const [newRoomDesc, setNewRoomDesc] = useState('');
  const [contentTab, setContentTab] = useState<'messages' | 'files' | 'members'>('messages');
  const [roomMembers, setRoomMembers] = useState<RoomMember[]>([]);
  const [showInviteModal, setShowInviteModal] = useState(false);
  const [inviteUsers, setInviteUsers] = useState<PrzmaUser[]>([]);
  const [inviteSearch, setInviteSearch] = useState('');
  const [inviteLoading, setInviteLoading] = useState(false);
  const [dmLoading, setDmLoading] = useState<string | null>(null);
  const [dmLastMessages, setDmLastMessages] = useState<Record<string, { body: string; username: string; isOwn: boolean }>>({});
  const [hasMoreMessages, setHasMoreMessages] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [showDmModal, setShowDmModal] = useState(false);
  const [dmModalSearch, setDmModalSearch] = useState('');
  const [dmModalUsers, setDmModalUsers] = useState<PrzmaUser[]>([]);
  const [dmModalLoading, setDmModalLoading] = useState(false);
  const [presenceMap, setPresenceMap] = useState<Record<string, { username: string }>>({});
  const [myUserId, setMyUserId] = useState<string | null>(null);
  const socketRef = useRef<Socket | null>(null);
  const channelRef = useRef<Channel | null>(null);
  const userChannelRef = useRef<Channel | null>(null);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);
  const typingTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const curPanelRef = useRef(curPanel);

  const [docs, setDocs] = useState<Doc[]>([]);
  const [thumbnails, setThumbnails] = useState<Record<string, string>>({});
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
  const [serverUrl, setServerUrl] = useState("http://172.235.18.126:4201");
  const [showServerSettings, setShowServerSettings] = useState(false);

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
      loadDocs();
      const interval = setInterval(loadDocs, 5000);
      // Connect the chat socket eagerly so the nav dot and presence are ready
      // regardless of which panel the user visits first.
      initChatSocket();
      return () => clearInterval(interval);
    }
  }, [view, curPanel, searchQuery]);

  // Bulk fetch thumbnails when document list updates
  useEffect(() => {
    const imageIds = docs.filter(d => (d.content_type || "").toLowerCase().startsWith("image/")).map(d => d.id);
    if (imageIds.length > 0) {
      invoke<{doc_id: string, data_b64: string}[]>("get_thumbnails_bulk", { docIds: imageIds })
        .then(res => {
          const map: Record<string, string> = {};
          res.forEach(r => { map[r.doc_id] = r.data_b64; });
          setThumbnails(map);
        })
        .catch(console.error);
    } else {
      setThumbnails({});
    }
  }, [docs]);

  const loadDocs = async () => {
    try {
      if (searchQuery.trim().length > 0) {
        // Native FTS Search — matches against filename AND text_content
        const results = await invoke<Doc[]>("search_documents", {
          vaultName: activeVault,
          query: searchQuery
        });
        setDocs(results);
        return;
      }

      // Default Arrow IPC path (Instant Scroll)
      const result: { ipc_base64: string, record_count: number } = await invoke("get_documents_arrow", { vaultName: activeVault });
      
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
        setDocs(await invoke<Doc[]>("list_documents", { vaultName: activeVault }));
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
    console.log("Logout: Button clicked");
    try {
      let ok = false;
      try {
        ok = await ask("Are you sure you want to sign out?", { title: "Sign Out", kind: "warning" });
      } catch (e) {
        console.warn("Native dialog failed, falling back to window.confirm", e);
        ok = window.confirm("Are you sure you want to sign out?");
      }
      console.log("Logout: Confirm result =", ok);
      if (!ok) return;
      
      console.log("Logout: Invoking hard reset...");
      await invoke("clear_local_data").catch(e => {
        console.error("Logout: Reset failed (ignoring):", e);
      });
      
      console.log("Logout: Cleaning local state");
      // Disconnect Phoenix socket + channels so no state leaks to next user
      if (channelRef.current) { channelRef.current.leave(); channelRef.current = null; }
      if (userChannelRef.current) { userChannelRef.current.leave(); userChannelRef.current = null; }
      if (socketRef.current) { socketRef.current.disconnect(); socketRef.current = null; }
      // Clear all chat state — also reset panel so useEffect fires on next Teams visit
      setChatRooms([]); setActiveRoom(null); setChatMessages([]);
      setChatInput(''); setChatTyping([]); setChatConnected(false);
      setRoomMembers([]); setPresenceMap({}); setMyUserId(null);
      setCurPanel('personal');
      setUsername(null);
      setDocs([]);
      localStorage.removeItem("przma_username");
      setView("auth");
      setAuthMode("login");
      console.log("Logout: View changed to auth");
    } catch (e: any) {
      console.error("Logout: Unexpected error:", e);
      addToast("Logout failed: " + e, "error");
      // Fallback: force view change anyway
      setView("auth");
      setAuthMode("login");
    }
  };

  const handleUpload = async () => {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({ multiple: true });
    if (!selected) return;
    const paths = Array.isArray(selected) ? selected : [selected];
    addToast(`Syncing ${paths.length} file(s)...`, "info");
    
    try {
      const category = activeVault.replace("_vault", "");
      const results: { filename: string, status: string, error?: string }[] = 
        await invoke("upload_files_from_paths", { paths, vaultName: activeVault, category });
      
      const skipped = results.filter(r => r.status === "skipped");
      const done = results.filter(r => r.status === "done");
      const errors = results.filter(r => r.status === "error");

      if (done.length > 0) addToast(`${done.length} files added to vault`, "success");
      if (skipped.length > 0) {
        const skipList = skipped.map(s => s.filename).join(", ");
        addToast(`Duplicates skipped: ${skipList}`, "info");
      }
      if (errors.length > 0) {
        addToast(`${errors.length} uploads failed`, "error");
      }

      loadDocs();
    } catch (e: any) { 
      console.error("Upload failed:", e);
      addToast(e, "error"); 
    }
  };

  const handleDirectShare = async (user: PrzmaUser) => {
    if (!shareModal) return;
    setShareLoading(true);
    try {
      const result = await invoke<any>("share_file", {
        docId:           shareModal.doc.id,
        sourceVault:     activeVault,
        targetVault:     "personal_vault",
        recipientUserId: user.id,
        permission:      "read",
        expiresIn:       604800,
      });
      if (result.success) {
        addToast(`Shared with @${user.nickname}`, "success");
        setShareModal(null);
        setShareUserSearch('');
        setShareUsers([]);
      } else {
        addToast("Share failed", "error");
      }
    } catch (e: any) { addToast(e, "error"); }
    finally { setShareLoading(false); }
  };

  const openShareModal = async (doc: Doc) => {
    setShareModal({ doc });
    setShareUserSearch('');
    try {
      const users = await invoke<PrzmaUser[]>('list_chat_users', { search: null });
      setShareUsers(users);
    } catch (_) {}
  };

  const loadIncomingShares = async () => {
    try {
      const list = await invoke<any[]>("get_incoming_shares");
      setIncomingShares(list || []);
    } catch (_) {}
  };

  const handleAcceptShare = async (token: string, targetVault: string) => {
    try {
      const result = await invoke<any>("accept_share", { shareToken: token, targetVault });
      if (result.success && result.download_url) {
        window.open(result.download_url, "_blank");
        addToast(`Opened: ${result.filename}`, "success");
      } else {
        addToast("Could not open share", "error");
      }
    } catch (e: any) { addToast(e, "error"); }
  };

  // ── Chat handlers ─────────────────────────────────────────────────────────

  const vaultColor = (v: string) =>
    v === 'personal' ? '#4A9EFF' : v === 'private' ? '#FFB800' : '#00E0C6';

  const avatarColor = (uid: string) => {
    const colors = ['#4A9EFF', '#FFB800', '#00E0C6', '#a78bfa', '#f87171', '#34d399'];
    let h = 0;
    for (let i = 0; i < uid.length; i++) h = (h * 31 + uid.charCodeAt(i)) & 0xffff;
    return colors[h % colors.length];
  };

  const initChatSocket = useCallback(async () => {
    if (socketRef.current?.isConnected()) return;
    try {
      const creds = await invoke<{ server_url: string; access_token: string; user_id?: string }>('get_chat_credentials');
      if (creds.user_id) setMyUserId(creds.user_id);
      const wsUrl = creds.server_url.replace(/^http/, 'ws') + '/chat';
      const socket = new Socket(wsUrl, { params: { token: creds.access_token } });
      socket.onOpen(() => setChatConnected(true));
      socket.onClose(() => setChatConnected(false));
      socket.connect();
      socketRef.current = socket;

      // Subscribe to personal user topic for invite notifications
      if (creds.user_id) {
        const uch = socket.channel(`user:${creds.user_id}`);
        uch.on('room_invite', (room: ChatRoom) => {
          addToast(`You were invited to #${room.name}`, 'success');
          setChatRooms(prev => prev.some(r => r.id === room.id) ? prev : [...prev, room]);
        });
        uch.join().receive('error', () => {});
        userChannelRef.current = uch;
      }
    } catch (e: any) { addToast('Chat connect failed: ' + e, 'error'); }
  }, []);

  const loadChatRooms = useCallback(async (vault: string) => {
    try {
      const rooms = await invoke<ChatRoom[]>('list_chat_rooms', { vault });
      setChatRooms(rooms);
    } catch (_) {}
  }, []);

  const loadRoomMembers = useCallback(async (roomId: string) => {
    try {
      const members = await invoke<RoomMember[]>('get_room_members', { roomId });
      setRoomMembers(members);
    } catch (_) {}
  }, []);

  const joinRoom = useCallback(async (room: ChatRoom) => {
    if (channelRef.current) {
      channelRef.current.leave();
      channelRef.current = null;
    }
    setActiveRoom(room);
    setChatMessages([]);
    setPresenceMap({});
    setHasMoreMessages(false);
    setLoadingMore(false);
    // Teams channels open Members tab by default; DMs always go straight to messages
    setContentTab(curPanelRef.current === 'teams' && !room.is_dm ? 'members' : 'messages');

    // Load cached messages first for instant display
    try {
      const local = await invoke<any[]>('get_local_chat_messages', { roomId: room.id, limit: 50 });
      if (local.length > 0) {
        const mapped: ChatMessage[] = local.map((m: any) => ({
          id: m.id, room_id: m.room_id, vault: m.vault,
          user_id: m.user_id, username: m.username, body: m.body,
          msg_type: m.msg_type, file_doc_id: m.file_doc_id,
          file_name: m.file_name, file_type: m.file_type,
          inserted_at: m.inserted_at
        }));
        setChatMessages(mapped);
      }
    } catch (_) {}

    if (!socketRef.current?.isConnected()) await initChatSocket();

    const topic = `vault_chat:${room.vault}:${room.id}`;
    const channel = socketRef.current!.channel(topic);

    channel.on('message_history', ({ messages }: { messages: ChatMessage[] }) => {
      setChatMessages(messages);
      messages.forEach(m => cacheMessage(m));
      // There may be older messages on the server if we got a full page
      setHasMoreMessages(messages.length >= 50);
      // Track last message for DM preview
      if (room.is_dm && messages.length > 0) {
        const last = messages[messages.length - 1];
        setDmLastMessages(prev => ({
          ...prev,
          [room.id]: { body: last.body || '📎 File', username: last.username, isOwn: String(last.user_id) === myUserId }
        }));
      }
      setTimeout(() => messagesEndRef.current?.scrollIntoView({ behavior: 'auto' }), 100);
    });

    channel.on('new_message', (msg: ChatMessage) => {
      setChatMessages(prev => {
        if (prev.some(m => m.id === msg.id)) return prev;
        return [...prev, msg];
      });
      cacheMessage(msg);
      // Track last message for DM preview
      if (room.is_dm) {
        setDmLastMessages(prev => ({
          ...prev,
          [room.id]: { body: msg.body || '📎 File', username: msg.username, isOwn: String(msg.user_id) === myUserId }
        }));
      }
      setTimeout(() => messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' }), 50);
    });

    channel.on('message_deleted', ({ id }: { id: string }) => {
      setChatMessages(prev => prev.filter(m => m.id !== id));
    });

    channel.on('typing', ({ username: u }: { username: string }) => {
      setChatTyping(prev => prev.includes(u) ? prev : [...prev, u]);
      setTimeout(() => setChatTyping(prev => prev.filter(x => x !== u)), 3000);
    });

    channel.on('presence_state', (state: any) => {
      const map: Record<string, { username: string }> = {};
      Object.entries(state).forEach(([uid, meta]: [string, any]) => {
        const metas = meta.metas || [];
        if (metas.length > 0) map[uid] = { username: metas[0].username };
      });
      setPresenceMap(map);
    });

    channel.on('presence_diff', ({ joins, leaves }: { joins: any; leaves: any }) => {
      setPresenceMap(prev => {
        const updated = { ...prev };
        Object.keys(leaves).forEach(uid => { delete updated[uid]; });
        Object.entries(joins).forEach(([uid, meta]: [string, any]) => {
          const metas = (meta as any).metas || [];
          if (metas.length > 0) updated[uid] = { username: metas[0].username };
        });
        return updated;
      });
    });

    channel.on('member_list', ({ members }: { members: RoomMember[] }) => {
      setRoomMembers(members);
    });

    channel.on('room_deleted', ({ room_id }: { room_id: string }) => {
      setChatRooms(prev => prev.filter(r => r.id !== room_id));
      setActiveRoom(prev => prev?.id === room_id ? null : prev);
      if (activeRoom?.id === room_id) {
        setChatMessages([]);
        channelRef.current?.leave();
        channelRef.current = null;
      }
    });

    channel.join()
      .receive('ok', () => {
        loadRoomMembers(room.id);
      })
      .receive('error', (e: any) => addToast('Room join failed: ' + JSON.stringify(e), 'error'));

    channelRef.current = channel;
  }, [initChatSocket, loadRoomMembers]);

  const cacheMessage = async (msg: ChatMessage) => {
    try {
      await invoke('store_chat_message', {
        id:         msg.id,
        roomId:     msg.room_id,
        vault:      msg.vault,
        userId:     String(msg.user_id),
        username:   msg.username,
        body:       msg.body ?? null,
        msgType:    msg.msg_type,
        fileDocId:  msg.file_doc_id ?? null,
        fileName:   msg.file_name ?? null,
        fileType:   msg.file_type ?? null,
        insertedAt: msg.inserted_at ?? new Date().toISOString(),
      });
    } catch (_) {}
  };

  const loadOlderMessages = async () => {
    if (!activeRoom || loadingMore || !hasMoreMessages) return;
    const firstId = chatMessages[0]?.id;
    if (!firstId) return;
    setLoadingMore(true);
    try {
      const older = await invoke<ChatMessage[]>('fetch_room_messages', {
        roomId:   activeRoom.id,
        limit:    50,
        beforeId: firstId,
      });
      if (older.length === 0) { setHasMoreMessages(false); return; }
      setChatMessages(prev => [...older, ...prev]);
      setHasMoreMessages(older.length >= 50);
    } catch (_) {}
    finally { setLoadingMore(false); }
  };

  const sendChatMessage = async () => {
    const body = chatInput.trim();
    if (!body || !activeRoom) return;

    // @username <message> → open DM room and send message there
    const mentionMatch = body.match(/^@(\S+)\s+([\s\S]+)$/);
    if (mentionMatch && !activeRoom.is_dm) {
      const [, mentionedUsername, dmBody] = mentionMatch;
      const target = roomMembers.find(m => m.username === mentionedUsername);
      if (target) {
        setChatInput('');
        try {
          // Get-or-create the DM room, then navigate to it
          const dmRoom = await invoke<ChatRoom>('create_dm_room', {
            targetUserId:   target.user_id,
            targetUsername: target.username,
            vault:          activeRoom.vault,
          });
          setChatRooms(prev => prev.some(r => r.id === dmRoom.id) ? prev : [...prev, dmRoom]);
          // joinRoom switches the channel — the message will be sent once the channel is ready
          await joinRoom(dmRoom);
          // Small delay so the channel.join() receive('ok') fires before we push
          setTimeout(() => {
            if (channelRef.current) {
              channelRef.current.push('send_message', { body: dmBody.trim(), msg_type: 'text' })
                .receive('error', () => {});
            }
          }, 300);
        } catch (e: any) { addToast('DM failed: ' + e, 'error'); }
        return;
      }
    }

    if (!channelRef.current) return;
    channelRef.current.push('send_message', { body, msg_type: 'text' })
      .receive('error', (e: any) => addToast('Send failed: ' + JSON.stringify(e), 'error'));
    setChatInput('');
  };

  const sendFileMessage = (doc: Doc) => {
    if (!channelRef.current || !activeRoom) {
      addToast('Select a room first', 'error'); return;
    }
    channelRef.current.push('send_message', {
      body:        `Shared file: ${doc.filename}`,
      msg_type:    doc.content_type?.startsWith('image/') ? 'image' : 'file',
      file_doc_id: doc.id,
      file_name:   doc.filename,
      file_type:   doc.content_type,
    }).receive('error', (e: any) => addToast('File share failed: ' + JSON.stringify(e), 'error'));
    addToast(`Shared "${doc.filename}" to #${activeRoom.name}`, 'success');
  };

  const handleChatKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChatMessage(); return; }
    if (channelRef.current) {
      channelRef.current.push('typing', {});
      if (typingTimerRef.current) clearTimeout(typingTimerRef.current);
    }
  };

  const handleCreateRoom = async () => {
    if (!newRoomName.trim()) return;
    try {
      const room = await invoke<ChatRoom>('create_chat_room', {
        vault: chatVault, name: newRoomName.trim(), description: newRoomDesc.trim() || null,
      });
      setChatRooms(prev => [...prev, room]);
      setShowNewRoomModal(false);
      setNewRoomName(''); setNewRoomDesc('');
      joinRoom(room);
    } catch (e: any) { addToast(e, 'error'); }
  };

  const handleLeaveRoom = async (room: ChatRoom) => {
    try {
      await invoke('leave_room', { roomId: room.id });
      if (channelRef.current) { channelRef.current.leave(); channelRef.current = null; }
      setChatRooms(prev => prev.filter(r => r.id !== room.id));
      if (activeRoom?.id === room.id) { setActiveRoom(null); setChatMessages([]); }
      addToast(`Left #${room.name}`, 'info');
    } catch (e: any) { addToast(e, 'error'); }
  };

  const handleDeleteRoom = async (room: ChatRoom) => {
    let ok = false;
    try {
      ok = await ask(`Delete #${room.name}? This removes all messages and members permanently.`, { title: "Delete Room", kind: "warning" });
    } catch {
      ok = window.confirm(`Delete #${room.name}? This removes all messages and members.`);
    }
    if (!ok) return;
    try {
      await invoke('delete_chat_room', { roomId: room.id });
      if (channelRef.current) { channelRef.current.leave(); channelRef.current = null; }
      setChatRooms(prev => prev.filter(r => r.id !== room.id));
      if (activeRoom?.id === room.id) { setActiveRoom(null); setChatMessages([]); }
      addToast(`Deleted #${room.name}`, 'info');
    } catch (e: any) { addToast(e, 'error'); }
  };

  const handleJoinByCode = async () => {
    const code = joinCodeInput.trim();
    if (!code) return;
    try {
      const room = await invoke<ChatRoom>('join_room', { roomId: code });
      setJoinCodeInput('');
      setChatRooms(prev => prev.some(r => r.id === room.id) ? prev : [...prev, room]);
      joinRoom(room);
      addToast(`Joined #${room.name}`, 'success');
    } catch (e: any) { addToast('Invalid code or already a member', 'error'); }
  };

  const openInviteModal = async () => {
    setShowInviteModal(true);
    setInviteLoading(true);
    try {
      const users = await invoke<PrzmaUser[]>('list_chat_users', { search: null });
      setInviteUsers(users);
    } catch (_) {}
    finally { setInviteLoading(false); }
  };

  const handleInviteUser = async (user: PrzmaUser) => {
    if (!activeRoom) return;
    try {
      await invoke('invite_to_room', {
        roomId:         activeRoom.id,
        targetUserId:   user.id,
        targetUsername: user.nickname,
      });
      addToast(`Invited @${user.nickname} to #${activeRoom.name}`, 'success');
      loadRoomMembers(activeRoom.id);
    } catch (e: any) { addToast(e, 'error'); }
  };

  const handleStartDm = async (user: PrzmaUser) => {
    setDmLoading(user.id);
    try {
      const room = await invoke<ChatRoom>('create_dm_room', {
        targetUserId:   user.id,
        targetUsername: user.nickname,
        vault:          chatVault,
      });
      setShowInviteModal(false);
      setInviteSearch('');
      setChatRooms(prev => prev.some(r => r.id === room.id) ? prev : [...prev, room]);
      joinRoom(room);
      addToast(`DM with @${user.nickname} opened`, 'success');
    } catch (e: any) { addToast('DM failed: ' + e, 'error'); }
    finally { setDmLoading(null); }
  };

  const filteredInviteUsers = inviteUsers.filter(u => {
    if (!inviteSearch) return true;
    const q = inviteSearch.toLowerCase();
    return u.nickname.toLowerCase().includes(q) || (u.name || '').toLowerCase().includes(q);
  });

  const openDmModal = async () => {
    setShowDmModal(true);
    setDmModalSearch('');
    setDmModalLoading(true);
    try {
      const users = await invoke<PrzmaUser[]>('list_chat_users', { search: null });
      setDmModalUsers(users);
    } catch (_) {}
    finally { setDmModalLoading(false); }
  };

  const filteredDmModalUsers = dmModalUsers.filter(u => {
    if (!dmModalSearch) return true;
    const q = dmModalSearch.toLowerCase();
    return u.nickname.toLowerCase().includes(q) || (u.name || '').toLowerCase().includes(q);
  });

  // Keep the panel ref in sync so joinRoom can read the current panel without a stale closure
  useEffect(() => { curPanelRef.current = curPanel; }, [curPanel]);

  // Initialize socket and load rooms when entering Teams or Social panel
  useEffect(() => {
    if (curPanel === 'teams' || curPanel === 'social') {
      setActiveRoom(null); setChatMessages([]); setRoomMembers([]);
      setRoomsTab('all'); setContentTab('messages');
      initChatSocket();
      loadChatRooms(chatVault);
    }
  }, [curPanel]);

  const handleSaveEdit = async () => {
    if (!pendingEdit) return;
    setLoading(true);
    try {
      await invoke("save_edited_file", {
        id: pendingEdit.id,
        localPath: pendingEdit.localPath,
        currentVersion: pendingEdit.version,
        vaultName: activeVault,
      });
      setPendingEdit(null);
      loadDocs();
      addToast("Saved — version updated", "success");
    } catch (e: any) { addToast(e, "error"); }
    finally { setLoading(false); }
  };

  const handleDocDelete = async (id: string) => {
    let ok = false;
    try {
      ok = await ask("Permanently delete this artifact? This action cannot be undone.", { title: "Delete Artifact", kind: "error" });
    } catch (e) {
      console.warn("Native dialog failed, falling back to window.confirm", e);
      ok = window.confirm("Permanently delete this artifact?");
    }
    if (ok) {
      try {
        await invoke("delete_document", { id, vaultName: activeVault });
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
        </div>

        {authMode !== "forgot" && regStep !== 3 && (
          <div style={{ display: 'flex', gap: 6, marginBottom: 32, background: 'rgba(0,0,0,0.3)', padding: 6, border: '1px solid rgba(255,255,255,0.05)', borderRadius: 18, boxShadow: 'inset 0 2px 8px rgba(0,0,0,0.4)' }}>
            <button
              className="btn"
              style={{ flex: 1, border: 'none', background: authMode === "login" ? 'rgba(255,255,255,0.08)' : 'transparent', color: authMode === "login" ? '#FFF' : 'rgba(255,255,255,0.4)', boxShadow: authMode === "login" ? '0 4px 12px rgba(0,0,0,0.2)' : 'none', fontWeight: authMode === "login" ? 700 : 500 }}
              onClick={() => { setAuthMode("login"); setLoginMsg(null); }}
            >
              Sign In
            </button>
            <button
              className="btn"
              style={{ flex: 1, border: 'none', background: authMode === "register" ? 'rgba(255,255,255,0.08)' : 'transparent', color: authMode === "register" ? '#FFF' : 'rgba(255,255,255,0.4)', boxShadow: authMode === "register" ? '0 4px 12px rgba(0,0,0,0.2)' : 'none', fontWeight: authMode === "register" ? 700 : 500 }}
              onClick={() => { setAuthMode("register"); setRegMsg(null); if (!captcha) loadCaptcha(); }}
            >
              Create Account
            </button>
          </div>
        )}

        <div className="auth-scroll-area" style={{ position: 'relative' }}>
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

        <div style={{ marginTop: 24, borderTop: '1px solid rgba(255,255,255,0.06)', paddingTop: 16 }}>
          <button 
            onClick={() => setShowServerSettings(!showServerSettings)}
            style={{ background: 'transparent', border: 'none', color: 'rgba(255,255,255,0.3)', fontSize: 11, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6, margin: '0 auto' }}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
            {showServerSettings ? "Hide Server Settings" : "Server Settings"}
          </button>

          {showServerSettings && (
            <div style={{ marginTop: 16, background: 'rgba(0,0,0,0.2)', padding: 16, borderRadius: 12, border: '1px solid rgba(255,255,255,0.05)' }}>
              <div style={{ fontSize: 10, fontWeight: 800, color: 'rgba(255,255,255,0.3)', marginBottom: 8, letterSpacing: 1 }}>SERVER URL</div>
              <div className="input-group" style={{ marginBottom: 12 }}>
                <input 
                  className="input" 
                  style={{ fontSize: 13, padding: '10px 14px' }}
                  value={serverUrl} 
                  onChange={e => setServerUrl(e.target.value)} 
                />
              </div>
              <button 
                className="btn" 
                style={{ width: '100%', fontSize: 11, height: 36, background: 'rgba(74, 158, 255, 0.1)', color: '#4A9EFF', borderColor: 'rgba(74, 158, 255, 0.2)' }}
                onClick={async () => {
                  try {
                    await invoke("update_server_url", { url: serverUrl });
                    addToast("Server URL updated", "success");
                    if (authMode === "register") loadCaptcha();
                  } catch (e: any) {
                    addToast(e, "error");
                  }
                }}
              >
                Apply Changes
              </button>
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
        {/* Violet — deep spectral anchor, top-left */}
        <div className="prism-orb prism-orb-1" style={{ top: 0, left: 0, background: 'rgba(88, 40, 240, 0.20)' }} />
        {/* Rose/magenta — spectrum counterpoint, bottom-right */}
        <div className="prism-orb prism-orb-2" style={{ top: 0, left: 0, background: 'rgba(220, 30, 130, 0.11)' }} />
        {/* Cyan — cool spectral highlight */}
        <div className="prism-orb prism-orb-3" style={{ top: 0, left: 0, background: 'rgba(0, 170, 255, 0.10)' }} />
        {/* Amber — warm refraction accent */}
        <div className="prism-orb prism-orb-4" style={{ top: 0, left: 0, background: 'rgba(200, 100, 255, 0.10)' }} />
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
              
              <select className="theme-select" value={theme} onChange={e => setTheme(e.target.value as any)}>
                <option value="prism">◈ Prism</option>
                <option value="dark">● Dark</option>
                <option value="light">○ Light</option>
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
          <button className={`nav-item ${curPanel === 'personal' ? 'active' : ''}`} onClick={() => setCurPanel('personal')}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
            Personal
          </button>

          <button className={`nav-item ${curPanel === 'teams' ? 'active' : ''}`} onClick={() => setCurPanel('teams')}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
            Teams
            {curPanel === 'teams' && chatConnected && <span style={{ marginLeft: 'auto', width: 6, height: 6, borderRadius: '50%', background: '#10B981', flexShrink: 0 }} />}
          </button>

          <button className={`nav-item ${curPanel === 'social' ? 'active' : ''}`} onClick={() => setCurPanel('social')}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>
            Social
            {curPanel === 'social' && chatConnected && <span style={{ marginLeft: 'auto', width: 6, height: 6, borderRadius: '50%', background: '#10B981', flexShrink: 0 }} />}
          </button>

          <div style={{ flex: 1 }} />
          <div style={{ padding: 12, borderRadius: 12, background: 'var(--accent-glow)', border: '1px solid rgba(88,166,255,0.2)', color: 'var(--accent)', fontSize: 10, fontWeight: 600, lineHeight: 1.5 }}>
            <div style={{ fontWeight: 700 }}>PRZMA Beta</div>
            <div style={{ opacity: 0.6 }}>Secure · Private · Distributed</div>
          </div>
        </nav>

        <main className="main">
          {curPanel === 'personal' && (
            <div className="panel">
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
                <div>
                  <h1 style={{ fontSize: 28, fontWeight: 800, marginBottom: 2 }}>Personal</h1>
                  <p style={{ color: 'var(--text-secondary)', fontSize: 13 }}>{docs.length} files</p>
                </div>
                <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                  <button
                    className="btn"
                    style={{ height: 36, padding: '0 16px', fontSize: 12, background: 'rgba(167,139,250,0.08)', color: '#a78bfa', borderColor: 'rgba(167,139,250,0.2)' }}
                    onClick={() => { setShowSharedPanel(true); loadIncomingShares(); }}
                  >
                    Inbox
                  </button>
                  <button
                    className="btn btn-accent"
                    style={{ height: 36, padding: '0 16px', fontSize: 12 }}
                    onClick={handleUpload}
                  >
                    + Upload
                  </button>
                  <div className="sort-bar" style={{ margin: 0 }}>
                    <select className="sort-select" value={sortBy} onChange={e => setSortBy(e.target.value as any)}>
                      <option value="date">Date</option>
                      <option value="name">Name</option>
                      <option value="size">Size</option>
                    </select>
                  </div>
                </div>
              </div>

              <input 
                className="input" 
                placeholder="Search filenames and document contents (FTS)..." 
                value={searchQuery} 
                onChange={e => setSearchQuery(e.target.value)} 
              />

              <div className="scroll-content">
                <div className="doc-list">
                  {displayDocs.map((d: Doc) => (
                    <div key={d.id} className="card">
                      <div className="thumbnail-box">
                        <Thumbnail type={d.content_type || ''} filename={d.filename} id={d.id} vaultName={activeVault} preloadedSrc={thumbnails[d.id]} />
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
                            const localPath = await invoke<string>("open_file_for_edit", { id: d.id, filename: d.filename, vaultName: activeVault });
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
                            const bytes = await invoke<number[]>("get_file_bytes", { id: d.id, vaultName: activeVault });
                            await writeFile(savePath, new Uint8Array(bytes));
                            addToast("File saved safely", "success");
                          } catch (e: any) { addToast(e, "error"); }
                        }}><IconDownload /></button>

                        <button className="btn doc-action-btn" style={{ width: 44, height: 36, color: '#a78bfa', borderColor: 'rgba(167,139,250,0.3)' }} title="Share" onClick={() => openShareModal(d)}><IconShare /></button>

                        <button className="btn doc-action-btn btn-danger" style={{ width: 44, height: 36 }} title="Delete" onClick={() => handleDocDelete(d.id)}><IconDelete /></button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          )}

          {/* ── Teams / Social Panel ── */}
          {(curPanel === 'teams' || curPanel === 'social') && (
            <div className="panel" style={{ padding: 0, overflow: 'hidden' }}>
              <div className="chat-layout">

                {/* ── Left Sidebar ── */}
                <div className="chat-sidebar">
                  <div className="sidebar-head">
                    <span className="sidebar-head-title">{curPanel === 'teams' ? 'Teams' : 'Social'}</span>
                    <div className={`live-dot ${chatConnected ? 'on' : 'off'}`} title={chatConnected ? 'Live' : 'Offline'} />
                  </div>

                  {/* ── CHANNELS section ── */}
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 12px 4px' }}>
                    <span style={{ fontSize: 10, fontWeight: 800, color: 'var(--text-secondary)', letterSpacing: 0.8, opacity: 0.6 }}>CHANNELS</span>
                    <button className="new-room-btn" title="New channel" onClick={() => setShowNewRoomModal(true)} style={{ width: 20, height: 20, fontSize: 16, lineHeight: 1, borderRadius: 5 }}>+</button>
                  </div>

                  <div style={{ padding: '0 8px 4px', display: 'flex', gap: 4 }}>
                    {([['all', 'All'], ['mine', 'Mine'], ['joined', 'Joined']] as const).map(([tab, label]) => (
                      <button key={tab} className={`filter-pill ${roomsTab === tab ? 'active' : ''}`}
                        onClick={() => setRoomsTab(tab)} style={{ fontSize: 10, padding: '2px 8px' }}>
                        {label}
                      </button>
                    ))}
                  </div>

                  {(() => {
                    const channels = chatRooms.filter(r => !r.is_dm && (
                      roomsTab === 'all'    ? true :
                      roomsTab === 'mine'   ? r.is_owner === true :
                      /* joined = member but not owner */
                      (r.is_member !== false) && r.is_owner !== true
                    ));
                    return (
                      <div className="room-list" style={{ maxHeight: 200, overflowY: 'auto' }}>
                        {channels.length === 0
                          ? <div style={{ padding: '10px 12px', fontSize: 11, color: 'var(--text-secondary)', opacity: 0.5, textAlign: 'center' }}>
                              {curPanel === 'teams' ? 'No teams yet' : 'No rooms yet'}
                            </div>
                          : channels.map(room => (
                            <div key={room.id} className={`room-item ${activeRoom?.id === room.id ? 'active' : ''}`}
                              onClick={() => joinRoom(room)}>
                              <div className="room-dot" style={{ background: vaultColor(chatVault) }} />
                              <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                {room.name}
                              </span>
                              {room.is_full && (
                                <span style={{ fontSize: 9, fontWeight: 700, color: '#FFB800', background: 'rgba(255,184,0,0.1)', border: '1px solid rgba(255,184,0,0.2)', borderRadius: 3, padding: '1px 4px', flexShrink: 0 }}>FULL</span>
                              )}
                              <div className="room-actions" onClick={e => e.stopPropagation()}>
                                {curPanel === 'teams' && room.is_owner && (
                                  <button className="room-action-btn" title="Copy invite link" onClick={() => { navigator.clipboard.writeText(room.id); addToast('Invite link copied — share with your team', 'success'); }}>⎘</button>
                                )}
                                {room.is_owner
                                  ? <button className="room-action-btn danger" title="Delete room" onClick={() => handleDeleteRoom(room)}>🗑</button>
                                  : <button className="room-action-btn danger" title="Leave room" onClick={() => handleLeaveRoom(room)}>✕</button>
                                }
                              </div>
                            </div>
                          ))
                        }
                      </div>
                    );
                  })()}

                  {/* ── DIRECT MESSAGES section ── */}
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 12px 4px', borderTop: '1px solid var(--border)', marginTop: 4 }}>
                    <span style={{ fontSize: 10, fontWeight: 800, color: 'var(--text-secondary)', letterSpacing: 0.8, opacity: 0.6 }}>DIRECT MESSAGES</span>
                    <button className="new-room-btn" title="New DM" onClick={openDmModal} style={{ width: 20, height: 20, fontSize: 16, lineHeight: 1, borderRadius: 5 }}>+</button>
                  </div>

                  {(() => {
                    const dms = chatRooms.filter(r => r.is_dm);
                    return (
                      <div className="room-list" style={{ flex: 1, overflowY: 'auto' }}>
                        {dms.length === 0
                          ? <div style={{ padding: '10px 12px', fontSize: 11, color: 'var(--text-secondary)', opacity: 0.5, textAlign: 'center' }}>
                              No direct messages yet
                            </div>
                          : dms.map(room => {
                            const partnerName = room.partner_username || room.name;
                            const partnerId   = room.partner_user_id || '';
                            const isOnline    = !!(presenceMap[partnerId]);
                            const isActive    = activeRoom?.id === room.id;
                            const lastMsg     = dmLastMessages[room.id];
                            return (
                              <div key={room.id} className={`room-item ${isActive ? 'active' : ''}`}
                                onClick={() => joinRoom(room)}
                                style={{ alignItems: 'flex-start', padding: '7px 10px', gap: 8 }}>
                                <div style={{ position: 'relative', flexShrink: 0, marginTop: 1 }}>
                                  <div style={{ width: 28, height: 28, borderRadius: '50%', background: `${avatarColor(partnerId || room.id)}22`, color: avatarColor(partnerId || room.id), display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700 }}>
                                    {partnerName.charAt(0).toUpperCase()}
                                  </div>
                                  {isOnline && (
                                    <div style={{ position: 'absolute', bottom: -1, right: -1, width: 7, height: 7, borderRadius: '50%', background: '#10B981', border: '1.5px solid var(--bg-secondary)' }} />
                                  )}
                                </div>
                                <div style={{ flex: 1, minWidth: 0 }}>
                                  <div style={{ fontSize: 12, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                    {partnerName}
                                  </div>
                                  {lastMsg && (
                                    <div style={{ fontSize: 10, color: 'var(--text-secondary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', marginTop: 1, opacity: 0.7 }}>
                                      {lastMsg.isOwn ? 'You: ' : ''}{lastMsg.body}
                                    </div>
                                  )}
                                </div>
                                <div className="room-actions" onClick={e => e.stopPropagation()} style={{ flexShrink: 0, marginTop: 2 }}>
                                  <button className="room-action-btn danger" title="Close DM" onClick={() => handleLeaveRoom(room)}>✕</button>
                                </div>
                              </div>
                            );
                          })
                        }
                      </div>
                    );
                  })()}

                  {/* Join by code — Teams only */}
                  {curPanel === 'teams' && (
                    <div className="join-code-row">
                      <input
                        className="join-code-input"
                        placeholder="Paste invite code…"
                        value={joinCodeInput}
                        onChange={e => setJoinCodeInput(e.target.value)}
                        onKeyDown={e => e.key === 'Enter' && handleJoinByCode()}
                      />
                      <button
                        onClick={handleJoinByCode}
                        disabled={!joinCodeInput.trim()}
                        style={{ padding: '5px 10px', borderRadius: 7, border: `1px solid ${joinCodeInput.trim() ? vaultColor(chatVault) : 'var(--border)'}`, background: joinCodeInput.trim() ? `${vaultColor(chatVault)}18` : 'transparent', color: joinCodeInput.trim() ? vaultColor(chatVault) : 'var(--text-secondary)', fontSize: 11, fontWeight: 700, cursor: joinCodeInput.trim() ? 'pointer' : 'default', transition: 'all 0.15s', flexShrink: 0 }}
                      >
                        Join
                      </button>
                    </div>
                  )}
                </div>

                {/* ── Right: Content pane ── */}
                <div className="chat-content-pane">
                  {!activeRoom ? (
                    <div className="chat-empty-state">
                      <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.2" opacity={0.15}><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>
                      <div style={{ fontSize: 13, fontWeight: 600 }}>Select a room</div>
                      <div style={{ fontSize: 12, opacity: 0.4, textAlign: 'center', maxWidth: 200 }}>
                        {curPanel === 'teams' ? 'Private · Join via invite link · File sharing' : 'Open to all · Social · File sharing'}
                      </div>
                    </div>
                  ) : (<>
                    {/* Room header */}
                    <div className="content-room-header">
                      {activeRoom.is_dm ? (() => {
                        const partnerName = activeRoom.partner_username || activeRoom.name;
                        const partnerId   = activeRoom.partner_user_id || '';
                        const dmOnline    = !!(presenceMap[partnerId]);
                        return (<>
                          <div style={{ position: 'relative', flexShrink: 0 }}>
                            <div style={{ width: 32, height: 32, borderRadius: '50%', background: `${avatarColor(partnerId || activeRoom.id)}22`, color: avatarColor(partnerId || activeRoom.id), display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700 }}>
                              {partnerName.charAt(0).toUpperCase()}
                            </div>
                            {dmOnline && (
                              <div style={{ position: 'absolute', bottom: 0, right: 0, width: 9, height: 9, borderRadius: '50%', background: '#10B981', border: '2px solid var(--bg-header)' }} />
                            )}
                          </div>
                          <div style={{ flex: 1, minWidth: 0 }}>
                            <div style={{ fontWeight: 700, fontSize: 14, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                              {partnerName}
                            </div>
                            <div style={{ fontSize: 11, color: dmOnline ? '#10B981' : 'var(--text-secondary)', marginTop: 1, fontWeight: dmOnline ? 600 : 400 }}>
                              {dmOnline ? 'Active now' : 'Offline'}
                            </div>
                          </div>
                        </>);
                      })() : (<>
                        <div style={{ width: 28, height: 28, borderRadius: 7, background: `${vaultColor(chatVault)}15`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, flexShrink: 0, color: vaultColor(chatVault) }}>
                          #
                        </div>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div style={{ fontWeight: 700, fontSize: 14, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                            {activeRoom.name}
                          </div>
                          {activeRoom.description && <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginTop: 1 }}>{activeRoom.description}</div>}
                        </div>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
                          {activeRoom.is_full && (
                            <span style={{ fontSize: 10, fontWeight: 700, color: '#FFB800', background: 'rgba(255,184,0,0.08)', border: '1px solid rgba(255,184,0,0.2)', borderRadius: 4, padding: '2px 6px' }}>
                              AUDIENCE
                            </span>
                          )}
                          <span style={{ fontSize: 11, color: 'var(--text-secondary)' }}>
                            <span style={{ color: '#10B981', fontWeight: 600 }}>{Object.keys(presenceMap).length}</span> online
                          </span>
                          {activeRoom.is_owner && (
                            <button onClick={openInviteModal} style={{ padding: '4px 10px', borderRadius: 7, border: `1px solid ${vaultColor(chatVault)}40`, background: `${vaultColor(chatVault)}10`, color: vaultColor(chatVault), fontSize: 11, fontWeight: 700, cursor: 'pointer' }}>
                              + Invite
                            </button>
                          )}
                        </div>
                      </>)}
                    </div>

                    {/* Content tabs — DMs only show Messages */}
                    <div className="content-tabs-bar">
                      {(activeRoom.is_dm
                        ? [['messages', 'Messages']] as const
                        : [['messages', 'Messages'], ['files', 'Files'], ['members', `Members${roomMembers.length > 0 ? ` (${roomMembers.length})` : ''}`]] as const
                      ).map(([tab, label]) => (
                        <button key={tab} className={`content-tab ${contentTab === tab ? 'active' : ''}`}
                          onClick={() => setContentTab(tab as any)}>
                          {label}
                        </button>
                      ))}
                    </div>

                    {/* Content body */}
                    <div className="content-body">

                    {/* Messages tab */}
                    {contentTab === 'messages' && (<>
                    <div className="messages-list">
                      {hasMoreMessages && (
                        <div style={{ textAlign: 'center', padding: '8px 0 4px', flexShrink: 0 }}>
                          <button
                            onClick={loadOlderMessages}
                            disabled={loadingMore}
                            style={{ padding: '4px 14px', borderRadius: 6, border: '1px solid var(--border)', background: 'rgba(255,255,255,0.04)', color: 'var(--text-secondary)', fontSize: 11, fontWeight: 600, cursor: loadingMore ? 'default' : 'pointer', opacity: loadingMore ? 0.5 : 1, transition: 'all 0.15s' }}
                          >
                            {loadingMore ? 'Loading…' : '↑ Load older messages'}
                          </button>
                        </div>
                      )}
                      {chatMessages.length === 0 ? (
                        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', color: 'var(--text-secondary)', gap: 8, padding: 40 }}>
                          <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" opacity={0.3}><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>
                          <span style={{ fontSize: 13 }}>No messages yet</span>
                        </div>
                      ) : (() => {
                        const groups: { author: string; uid: string; msgs: ChatMessage[] }[] = [];
                        chatMessages.forEach(msg => {
                          const last = groups[groups.length - 1];
                          const sameAuthor = last && last.uid === String(msg.user_id);
                          if (sameAuthor) { last.msgs.push(msg); }
                          else { groups.push({ author: msg.username, uid: String(msg.user_id), msgs: [msg] }); }
                        });
                        return groups.map((group, gi) => {
                          const isOwn = group.uid === myUserId;
                          return (
                            <div key={gi} className="msg-group" style={isOwn ? { alignItems: 'flex-end' } : {}}>
                              <div className="msg-group-header" style={isOwn ? { flexDirection: 'row-reverse' } : {}}>
                                <div style={{ width: 26, height: 26, borderRadius: '50%', background: `${avatarColor(group.uid)}22`, color: avatarColor(group.uid), display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
                                  {group.author.charAt(0).toUpperCase()}
                                </div>
                                <span className={`msg-author ${isOwn ? 'own' : ''}`} style={{ color: isOwn ? '#a78bfa' : avatarColor(group.uid) }}>
                                  {group.author}
                                </span>
                                <span className="msg-time">
                                  {group.msgs[0].inserted_at ? (() => { const d = new Date(group.msgs[0].inserted_at); return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`; })() : ''}
                                </span>
                              </div>
                              <div className="msg-body-wrap" style={isOwn ? { display: 'flex', flexDirection: 'column', alignItems: 'flex-end' } : {}}>
                                {group.msgs.map((msg, mi) => {
                                  const isFile = msg.msg_type === 'file' || msg.msg_type === 'image';
                                  return isFile ? (
                                    <div key={msg.id || mi} className="msg-file-card" onClick={async () => {
                                      if (!msg.file_doc_id) return;
                                      const { save } = await import('@tauri-apps/plugin-dialog');
                                      const { writeFile } = await import('@tauri-apps/plugin-fs');
                                      const savePath = await save({ defaultPath: msg.file_name || 'file' });
                                      if (!savePath) return;
                                      try {
                                        const bytes = await invoke<number[]>('get_file_bytes', { id: msg.file_doc_id, vaultName: `${chatVault}_vault` });
                                        await writeFile(savePath, new Uint8Array(bytes));
                                        addToast('Downloaded: ' + msg.file_name, 'success');
                                      } catch (e: any) { addToast(e, 'error'); }
                                    }}>
                                      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ flexShrink: 0, color: vaultColor(chatVault) }}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
                                      <div style={{ flex: 1, minWidth: 0 }}>
                                        <div style={{ fontSize: 12, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{msg.file_name || 'Shared file'}</div>
                                        <div style={{ fontSize: 10, color: 'var(--text-secondary)' }}>Click to download · {msg.file_type || 'file'}</div>
                                      </div>
                                      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ opacity: 0.4 }}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                                    </div>
                                  ) : (
                                    <div key={msg.id || mi} className={`msg-body ${isOwn ? 'own' : ''}`} style={{ marginTop: mi > 0 ? 3 : 0 }}>
                                      {msg.body}
                                    </div>
                                  );
                                })}
                              </div>
                            </div>
                          );
                        });
                      })()}
                      <div ref={messagesEndRef} />
                    </div>

                    {/* Input */}
                    <div className="chat-input-area">
                      <div className="typing-indicator">
                        {chatTyping.length > 0 && `${chatTyping.join(', ')} ${chatTyping.length === 1 ? 'is' : 'are'} typing…`}
                      </div>
                      <div className="chat-input-row">
                        {!activeRoom.is_dm && (
                          <button title="Files" onClick={() => setContentTab('files')} style={{ width: 34, height: 34, borderRadius: 8, border: '1px solid var(--border)', background: (contentTab as string) === 'files' ? 'var(--accent-glow)' : 'rgba(255,255,255,0.03)', color: (contentTab as string) === 'files' ? 'var(--accent)' : 'var(--text-secondary)', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', transition: 'all 0.15s', flexShrink: 0 }}>
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>
                          </button>
                        )}
                        <textarea
                          className="chat-textarea"
                          placeholder={activeRoom.is_dm ? `Message ${activeRoom.partner_username || activeRoom.name}…` : `Message ${activeRoom.name}…`}
                          value={chatInput}
                          rows={1}
                          onChange={e => setChatInput(e.target.value)}
                          onKeyDown={handleChatKeyDown}
                        />
                        <button
                          style={{ width: 34, height: 34, borderRadius: 8, border: 'none', background: chatInput.trim() ? `linear-gradient(135deg, ${vaultColor(chatVault)} 0%, ${vaultColor(chatVault)}cc 100%)` : 'rgba(255,255,255,0.08)', color: '#fff', cursor: chatInput.trim() ? 'pointer' : 'default', transition: 'all 0.2s', flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}
                          onClick={sendChatMessage}
                          disabled={!chatInput.trim()}
                        >
                          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
                        </button>
                      </div>
                    </div>
                    </>)}

                    {/* Files tab */}
                    {contentTab === 'files' && (
                      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
                        <div style={{ padding: '8px 12px', borderBottom: '1px solid var(--border)', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                          <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-secondary)' }}>{docs.length} files</span>
                          <button onClick={handleUpload} style={{ padding: '4px 10px', borderRadius: 7, border: '1px solid var(--border)', background: 'rgba(255,255,255,0.04)', color: 'var(--text-secondary)', fontSize: 11, fontWeight: 700, cursor: 'pointer', transition: 'all 0.12s' }}
                            onMouseEnter={e => { (e.target as HTMLButtonElement).style.borderColor = 'var(--accent)'; (e.target as HTMLButtonElement).style.color = 'var(--accent)'; }}
                            onMouseLeave={e => { (e.target as HTMLButtonElement).style.borderColor = 'var(--border)'; (e.target as HTMLButtonElement).style.color = 'var(--text-secondary)'; }}>
                            + Upload
                          </button>
                        </div>
                        {docs.length === 0
                          ? <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, color: 'var(--text-secondary)' }}>No files yet</div>
                          : <div className="chat-file-browser">
                            {docs.map(d => (
                              <div key={d.id} className="chat-file-item">
                                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ flexShrink: 0, opacity: 0.4 }}><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/></svg>
                                <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{d.filename}</span>
                                <button className="file-share-btn" onClick={() => sendFileMessage(d)}>Share</button>
                              </div>
                            ))}
                          </div>
                        }
                      </div>
                    )}

                    {/* Members tab */}
                    {contentTab === 'members' && (
                      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
                        {!activeRoom.is_dm && activeRoom.is_owner && (
                          <div style={{ padding: '8px 12px', borderBottom: '1px solid var(--border)', display: 'flex', flexDirection: 'column', gap: 6 }}>
                            <button onClick={openInviteModal} style={{ width: '100%', padding: '7px 0', borderRadius: 8, border: `1px solid ${vaultColor(chatVault)}`, background: `${vaultColor(chatVault)}10`, color: vaultColor(chatVault), fontSize: 12, fontWeight: 700, cursor: 'pointer' }}>
                              + Add Member
                            </button>
                            {curPanel === 'teams' && (
                              <button onClick={() => { navigator.clipboard.writeText(activeRoom.id); addToast('Invite link copied — share with your team', 'success'); }} style={{ width: '100%', padding: '7px 0', borderRadius: 8, border: '1px solid rgba(255,255,255,0.12)', background: 'rgba(255,255,255,0.05)', color: 'var(--text-secondary)', fontSize: 12, fontWeight: 600, cursor: 'pointer' }}>
                                ⎘ Copy Invite Link
                              </button>
                            )}
                          </div>
                        )}
                        {roomMembers.length === 0
                          ? <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, color: 'var(--text-secondary)' }}>No members yet</div>
                          : <div style={{ overflowY: 'auto', padding: '4px 8px' }}>
                            {roomMembers.map(m => {
                              const isOnline = !!(presenceMap[m.user_id] || m.online);
                              const isMe     = m.user_id === myUserId;
                              return (
                                <div key={m.user_id} className="member-chip">
                                  <div style={{ position: 'relative', flexShrink: 0 }}>
                                    <div className="member-avatar" style={{ background: `${avatarColor(m.user_id)}22`, color: avatarColor(m.user_id) }}>
                                      {m.username.charAt(0).toUpperCase()}
                                    </div>
                                    {isOnline && (
                                      <div style={{ position: 'absolute', bottom: -1, right: -1, width: 7, height: 7, borderRadius: '50%', background: '#10B981', border: '1.5px solid var(--bg-secondary)' }} />
                                    )}
                                  </div>
                                  <div style={{ flex: 1, minWidth: 0 }}>
                                    <div style={{ fontSize: 12, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                      {m.username}
                                      {isMe && <span style={{ marginLeft: 4, fontSize: 10, opacity: 0.45 }}>you</span>}
                                    </div>
                                    <div style={{ fontSize: 10, color: 'var(--text-secondary)', opacity: 0.5, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                      {isOnline ? 'Online' : 'Offline'}
                                    </div>
                                  </div>
                                  <span className="role-badge" style={{ background: m.role === 'owner' ? 'rgba(255,184,0,0.12)' : 'rgba(255,255,255,0.05)', color: m.role === 'owner' ? '#FFB800' : 'var(--text-secondary)', fontSize: 9, fontWeight: 800, padding: '1px 5px', borderRadius: 4, letterSpacing: 0.3 }}>
                                    {m.role.toUpperCase()}
                                  </span>
                                  {!isMe && !activeRoom.is_dm && (
                                    <button
                                      title={`DM ${m.username}`}
                                      onClick={() => handleStartDm({ id: m.user_id, nickname: m.username, name: m.username })}
                                      style={{ padding: '3px 7px', borderRadius: 5, border: '1px solid var(--border)', background: 'rgba(255,255,255,0.03)', color: 'var(--text-secondary)', fontSize: 10, cursor: 'pointer', flexShrink: 0, transition: 'all 0.15s' }}
                                      onMouseEnter={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = vaultColor(chatVault); (e.currentTarget as HTMLButtonElement).style.color = vaultColor(chatVault); }}
                                      onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'var(--border)'; (e.currentTarget as HTMLButtonElement).style.color = 'var(--text-secondary)'; }}
                                    >
                                      DM
                                    </button>
                                  )}
                                </div>
                              );
                            })}
                          </div>
                        }
                      </div>
                    )}

                    </div>{/* end content-body */}
                  </>)}
                </div>
              </div>
            </div>
          )}
        </main>

        {/* ── New Room Modal ── */}
        {showNewRoomModal && (
          <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.75)', zIndex: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }} onClick={() => { setShowNewRoomModal(false); setNewRoomName(''); setNewRoomDesc(''); }}>
            <div style={{ width: '100%', maxWidth: 400, background: 'var(--bg-secondary)', border: '1px solid var(--border)', borderRadius: 16, padding: 24 }} onClick={e => e.stopPropagation()}>
              <div style={{ fontWeight: 700, fontSize: 15, marginBottom: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                {curPanel === 'teams'
                  ? <span style={{ fontSize: 16 }}>🔒</span>
                  : <span style={{ fontSize: 16 }}>🌐</span>}
                New {curPanel === 'teams' ? 'Team' : 'Social Room'}
              </div>
              <div style={{ fontSize: 12, color: 'var(--text-secondary)', marginBottom: 20, display: 'flex', alignItems: 'center', gap: 6 }}>
                {curPanel === 'teams'
                  ? <><span style={{ color: vaultColor(chatVault), fontWeight: 600 }}>Private</span> · Members join via your shareable link</>
                  : <><span style={{ color: vaultColor(chatVault), fontWeight: 600 }}>Public</span> · Open to everyone in Social</>}
              </div>

              <div style={{ marginBottom: 12 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--text-secondary)', marginBottom: 6, letterSpacing: 0.5 }}>
                  {curPanel === 'teams' ? 'TEAM NAME' : 'ROOM NAME'}
                </div>
                <input className="input" style={{ padding: '10px 14px', fontSize: 14 }} placeholder={curPanel === 'teams' ? 'e.g. engineering, design' : 'e.g. general, announcements'} value={newRoomName} onChange={e => setNewRoomName(e.target.value)} onKeyDown={e => e.key === 'Enter' && handleCreateRoom()} autoFocus />
              </div>
              <div style={{ marginBottom: 20 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--text-secondary)', marginBottom: 6, letterSpacing: 0.5 }}>DESCRIPTION (OPTIONAL)</div>
                <input className="input" style={{ padding: '10px 14px', fontSize: 13 }} placeholder="What's this for?" value={newRoomDesc} onChange={e => setNewRoomDesc(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 10 }}>
                <button className="btn" style={{ flex: 1 }} onClick={() => { setShowNewRoomModal(false); setNewRoomName(''); setNewRoomDesc(''); }}>Cancel</button>
                <button className="btn" style={{ flex: 1, background: `linear-gradient(135deg, ${vaultColor(chatVault)} 0%, ${vaultColor(chatVault)}cc 100%)`, color: '#fff', border: 'none', fontWeight: 700 }} onClick={handleCreateRoom} disabled={!newRoomName.trim()}>
                  Create {curPanel === 'teams' ? 'Team' : 'Room'}
                </button>
              </div>
            </div>
          </div>
        )}

        {/* ── Invite Modal ── */}
        {showInviteModal && (
          <div className="invite-modal-overlay" onClick={() => { setShowInviteModal(false); setInviteSearch(''); }}>
            <div className="invite-modal" onClick={e => e.stopPropagation()}>
              <div className="invite-modal-header">
                <div>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>Add to #{activeRoom?.name}</div>
                  <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginTop: 2 }}>Search by username</div>
                </div>
                <button onClick={() => { setShowInviteModal(false); setInviteSearch(''); }} style={{ background: 'none', border: 'none', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 18, lineHeight: 1 }}>✕</button>
              </div>

              <div style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)' }}>
                <input
                  className="input"
                  style={{ padding: '8px 12px', fontSize: 13 }}
                  placeholder="Search by username or name..."
                  value={inviteSearch}
                  onChange={e => setInviteSearch(e.target.value)}
                  autoFocus
                />
              </div>

              <div style={{ maxHeight: 320, overflowY: 'auto' }}>
                {inviteLoading ? (
                  <div style={{ padding: '24px', textAlign: 'center', color: 'var(--text-secondary)', fontSize: 13 }}>Loading users...</div>
                ) : filteredInviteUsers.length === 0 ? (
                  <div style={{ padding: '24px', textAlign: 'center', color: 'var(--text-secondary)', fontSize: 13 }}>No users found</div>
                ) : filteredInviteUsers.map(u => {
                  const alreadyMember = roomMembers.some(m => m.user_id === u.id);
                  const isMe = u.id === myUserId;
                  return (
                    <div key={u.id} className="user-pick-item">
                      <div className="user-avatar" style={{ color: avatarColor(u.id) }}>
                        {u.nickname.charAt(0).toUpperCase()}
                      </div>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 13, fontWeight: 600 }}>@{u.nickname}</div>
                        {u.name && u.name !== u.nickname && (
                          <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>{u.name}</div>
                        )}
                      </div>
                      {isMe ? (
                        <span style={{ fontSize: 11, color: 'var(--text-secondary)', padding: '4px 8px' }}>you</span>
                      ) : (
                        <div style={{ display: 'flex', gap: 5 }}>
                          {!alreadyMember && (
                            <button onClick={() => handleInviteUser(u)} style={{ padding: '5px 10px', borderRadius: 7, border: `1px solid ${vaultColor(chatVault)}`, background: `${vaultColor(chatVault)}12`, color: vaultColor(chatVault), fontSize: 12, fontWeight: 700, cursor: 'pointer' }}>
                              Invite
                            </button>
                          )}
                          {alreadyMember && <span style={{ fontSize: 11, color: '#10B981', fontWeight: 600, padding: '5px 0' }}>✓</span>}
                          <button
                            onClick={() => handleStartDm(u)}
                            disabled={dmLoading === u.id}
                            style={{ padding: '5px 10px', borderRadius: 7, border: '1px solid var(--border)', background: 'rgba(255,255,255,0.04)', color: 'var(--text-secondary)', fontSize: 12, fontWeight: 700, cursor: 'pointer', transition: 'all 0.15s' }}
                            onMouseEnter={e => { if (dmLoading !== u.id) { (e.currentTarget as HTMLButtonElement).style.borderColor = '#00E0C6'; (e.currentTarget as HTMLButtonElement).style.color = '#00E0C6'; } }}
                            onMouseLeave={e => { (e.currentTarget as HTMLButtonElement).style.borderColor = 'var(--border)'; (e.currentTarget as HTMLButtonElement).style.color = 'var(--text-secondary)'; }}
                          >
                            {dmLoading === u.id ? '...' : 'DM'}
                          </button>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        )}

        {/* ── New DM Modal ── */}
        {showDmModal && (
          <div className="invite-modal-overlay" onClick={() => { setShowDmModal(false); setDmModalSearch(''); }}>
            <div className="invite-modal" onClick={e => e.stopPropagation()}>
              <div className="invite-modal-header">
                <div>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>New Direct Message</div>
                  <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginTop: 2 }}>Start a private 1-on-1 conversation</div>
                </div>
                <button onClick={() => { setShowDmModal(false); setDmModalSearch(''); }} style={{ background: 'none', border: 'none', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 18, lineHeight: 1 }}>✕</button>
              </div>
              <div style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)' }}>
                <input
                  className="input"
                  style={{ padding: '8px 12px', fontSize: 13 }}
                  placeholder="Search by username or name..."
                  value={dmModalSearch}
                  onChange={e => setDmModalSearch(e.target.value)}
                  autoFocus
                />
              </div>
              <div style={{ maxHeight: 360, overflowY: 'auto' }}>
                {dmModalLoading ? (
                  <div style={{ padding: '24px', textAlign: 'center', color: 'var(--text-secondary)', fontSize: 13 }}>Loading users...</div>
                ) : filteredDmModalUsers.length === 0 ? (
                  <div style={{ padding: '24px', textAlign: 'center', color: 'var(--text-secondary)', fontSize: 13 }}>No users found</div>
                ) : filteredDmModalUsers.filter(u => u.id !== myUserId).map(u => {
                  const existingDm = chatRooms.find(r => r.is_dm && (r.partner_user_id === u.id || (r.dm_user_ids || []).includes(u.id)));
                  return (
                    <div key={u.id} className="user-pick-item" onClick={() => {
                      if (existingDm) {
                        setShowDmModal(false); setDmModalSearch('');
                        joinRoom(existingDm);
                      }
                    }}>
                      <div style={{ position: 'relative' }}>
                        <div className="user-avatar" style={{ color: avatarColor(u.id) }}>
                          {u.nickname.charAt(0).toUpperCase()}
                        </div>
                        {presenceMap[u.id] && (
                          <div style={{ position: 'absolute', bottom: 0, right: 0, width: 8, height: 8, borderRadius: '50%', background: '#10B981', border: '1.5px solid var(--bg-secondary)' }} />
                        )}
                      </div>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 13, fontWeight: 600 }}>{u.nickname}</div>
                        {u.name && u.name !== u.nickname && (
                          <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>{u.name}</div>
                        )}
                        {presenceMap[u.id] && (
                          <div style={{ fontSize: 10, color: '#10B981', fontWeight: 600, marginTop: 1 }}>Active now</div>
                        )}
                      </div>
                      {existingDm ? (
                        <span style={{ fontSize: 11, color: vaultColor(chatVault), fontWeight: 600, padding: '4px 8px', borderRadius: 6, border: `1px solid ${vaultColor(chatVault)}30`, background: `${vaultColor(chatVault)}10` }}>Open</span>
                      ) : (
                        <button
                          onClick={e => { e.stopPropagation(); handleStartDm(u); setShowDmModal(false); setDmModalSearch(''); }}
                          disabled={dmLoading === u.id}
                          style={{ padding: '5px 12px', borderRadius: 7, border: `1px solid ${vaultColor(chatVault)}`, background: `${vaultColor(chatVault)}12`, color: vaultColor(chatVault), fontSize: 12, fontWeight: 700, cursor: 'pointer', transition: 'all 0.15s' }}
                        >
                          {dmLoading === u.id ? '...' : 'Message'}
                        </button>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        )}

        {/* ── Share Modal ── */}
        {shareModal && (
          <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.75)', zIndex: 600, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }} onClick={() => { setShareModal(null); setShareUserSearch(''); setShareUsers([]); }}>
            <div style={{ width: '100%', maxWidth: 400, background: 'var(--bg-secondary)', border: '1px solid var(--border)', borderRadius: 16, overflow: 'hidden', boxShadow: '0 24px 64px rgba(0,0,0,0.5)' }} onClick={e => e.stopPropagation()}>
              <div style={{ padding: '16px 20px', borderBottom: '1px solid var(--border)', display: 'flex', alignItems: 'center', gap: 10 }}>
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>Share</div>
                  <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', maxWidth: 280 }}>{shareModal.doc.filename}</div>
                </div>
                <button onClick={() => { setShareModal(null); setShareUserSearch(''); setShareUsers([]); }} style={{ background: 'none', border: 'none', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: 18, lineHeight: 1 }}>✕</button>
              </div>

              <div style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)' }}>
                <input
                  className="input"
                  style={{ padding: '8px 12px', fontSize: 13 }}
                  placeholder="Search by username…"
                  value={shareUserSearch}
                  onChange={e => setShareUserSearch(e.target.value)}
                  autoFocus
                />
              </div>

              <div style={{ maxHeight: 300, overflowY: 'auto' }}>
                {shareUsers.length === 0 ? (
                  <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-secondary)', fontSize: 13 }}>Loading…</div>
                ) : (() => {
                  const q = shareUserSearch.toLowerCase();
                  const filtered = shareUsers.filter(u => !q || u.nickname.toLowerCase().includes(q) || (u.name || '').toLowerCase().includes(q));
                  return filtered.length === 0
                    ? <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-secondary)', fontSize: 13 }}>No users found</div>
                    : filtered.map(u => (
                      <div key={u.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 16px', borderBottom: '1px solid rgba(255,255,255,0.03)', transition: 'background 0.1s' }}
                        onMouseEnter={e => (e.currentTarget.style.background = 'rgba(255,255,255,0.03)')}
                        onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
                        <div className="user-avatar" style={{ color: avatarColor(u.id) }}>
                          {u.nickname.charAt(0).toUpperCase()}
                        </div>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div style={{ fontSize: 13, fontWeight: 600 }}>@{u.nickname}</div>
                          {u.name && u.name !== u.nickname && <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>{u.name}</div>}
                        </div>
                        {u.id === myUserId ? (
                          <span style={{ fontSize: 11, color: 'var(--text-secondary)', padding: '4px 8px' }}>you</span>
                        ) : (
                          <button
                            onClick={() => handleDirectShare(u)}
                            disabled={shareLoading}
                            style={{ padding: '5px 12px', borderRadius: 7, border: '1px solid var(--accent)', background: 'var(--accent-glow)', color: 'var(--accent)', fontSize: 12, fontWeight: 700, cursor: shareLoading ? 'default' : 'pointer', opacity: shareLoading ? 0.6 : 1 }}
                          >
                            Share
                          </button>
                        )}
                      </div>
                    ));
                })()}
              </div>
            </div>
          </div>
        )}

        {/* ── Incoming Shares Panel ── */}
        {showSharedPanel && (
          <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.75)', zIndex: 600, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }} onClick={() => setShowSharedPanel(false)}>
            <div style={{ width: '100%', maxWidth: 540, maxHeight: '80vh', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 16, display: 'flex', flexDirection: 'column', boxShadow: '0 24px 64px rgba(0,0,0,0.5)' }} onClick={e => e.stopPropagation()}>
              <div style={{ padding: '18px 24px', borderBottom: '1px solid var(--border)', display: 'flex', alignItems: 'center', gap: 10 }}>
                <span style={{ fontSize: 18 }}>📬</span>
                <span style={{ fontWeight: 700, fontSize: 14 }}>Shared with me</span>
                <button onClick={loadIncomingShares} style={{ marginLeft: 'auto', background: 'none', border: '1px solid var(--border)', borderRadius: 6, color: 'var(--text-dim)', padding: '4px 10px', fontSize: 11, cursor: 'pointer' }}>↻ Refresh</button>
                <button onClick={() => setShowSharedPanel(false)} style={{ background: 'none', border: 'none', color: 'var(--text-dim)', cursor: 'pointer', fontSize: 18, lineHeight: 1 }}>✕</button>
              </div>
              <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
                {incomingShares.length === 0 ? (
                  <div style={{ textAlign: 'center', padding: '40px 20px', color: 'var(--text-dim)' }}>
                    <div style={{ fontSize: 32, marginBottom: 10 }}>📭</div>
                    <div style={{ fontSize: 13 }}>No shares yet</div>
                  </div>
                ) : incomingShares.map((s: any, i: number) => (
                  <div key={i} style={{ padding: '12px 14px', border: '1px solid var(--border)', borderRadius: 10, marginBottom: 8, display: 'flex', alignItems: 'center', gap: 12 }}>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontWeight: 600, fontSize: 13, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.filename || s.doc_id}</div>
                      <div style={{ fontSize: 11, color: 'var(--text-dim)', marginTop: 3 }}>
                        From <span style={{ color: 'var(--accent)' }}>{s.source_vault}</span> → <span style={{ color: '#a78bfa' }}>{s.target_vault}</span>
                        {s.expires_at && <> · Expires {new Date(s.expires_at).toLocaleDateString()}</>}
                      </div>
                    </div>
                    <button onClick={() => handleAcceptShare(s.share_token, s.target_vault + '_vault')} style={{ padding: '6px 14px', borderRadius: 7, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 12, fontWeight: 600, cursor: 'pointer', flexShrink: 0 }}>
                      Open
                    </button>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

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
