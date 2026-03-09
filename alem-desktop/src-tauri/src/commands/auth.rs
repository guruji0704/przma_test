use tauri::State;
use crate::AppState;
use serde::{Deserialize, Serialize};

// ══════════════════════════════════════════════════════════════════════════
// Response Structs
// ══════════════════════════════════════════════════════════════════════════

#[derive(serde::Serialize)]
pub struct CaptchaResponse {
    pub answer_data: String,
    pub token: String,
    pub r#type: String,
    pub seconds_valid: i64,
}

#[derive(Deserialize)]
struct ApiMessageResponse {
    message: Option<String>,
    error: Option<String>,
    user_id: Option<String>,
    email: Option<String>,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub success: bool,
    pub user_id: Option<String>,
    pub email: Option<String>,
    pub message: String,
}

#[derive(Serialize)]
pub struct LoginResponse {
    pub success: bool,
    pub did: Option<String>,
    pub access_token: Option<String>,
}

#[derive(Serialize)]
pub struct GenericResponse {
    pub success: bool,
    pub message: String,
}

// ══════════════════════════════════════════════════════════════════════════
// Helper
// ══════════════════════════════════════════════════════════════════════════

async fn get_server_url(conn: &libsql::Connection) -> String {
    let real_url = "http://localhost:4000"; 

    if let Ok(mut rows) = conn
        .query("SELECT server_url FROM local_identity WHERE id = 'singleton'", ())
        .await
    {
        if let Ok(Some(row)) = rows.next().await {
            if let Ok(libsql::Value::Text(s)) = row.get_value(0) {
                if !s.is_empty() && !s.contains("localhost") {
                    return s;
                }
            }
        }
    }
    
    real_url.to_string()
}

fn get_text(row: &libsql::Row, idx: i32) -> String {
    match row.get_value(idx).ok() {
        Some(libsql::Value::Text(s)) => s,
        _ => String::new(),
    }
}

// ══════════════════════════════════════════════════════════════════════════
// Commands
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn get_captcha(state: State<'_, AppState>) -> Result<CaptchaResponse, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let server_url = get_server_url(&conn).await;

    let resp = reqwest::Client::new()
        .get(format!("{}/api/v1/pleroma/captcha", server_url))
        .send().await
        .map_err(|e| format!("Network error: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("Server error: {}", resp.status()));
    }

    let c: serde_json::Value = resp.json().await
        .map_err(|e| format!("Failed to parse captcha: {}", e))?;

    Ok(CaptchaResponse {
        answer_data:   c["answer_data"].as_str().unwrap_or("").to_string(),
        token:         c["token"].as_str().unwrap_or("").to_string(),
        r#type:        c["type"].as_str().unwrap_or("").to_string(),
        seconds_valid: c["seconds_valid"].as_i64().unwrap_or(0),
    })
}

#[tauri::command]
pub async fn register_account(
    nickname: String,
    email: String,
    password: String,
    captcha_solution: String,
    captcha_token: String,
    state: State<'_, AppState>,
) -> Result<RegisterResponse, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let server_url = get_server_url(&conn).await;

    log::info!("Registering: {} @ {}", nickname, server_url);

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/register", server_url))
        .json(&serde_json::json!({
            "nickname":         nickname,
            "email":            email,
            "password":         password,
            "captcha_solution": captcha_solution,
            "captcha_token":    captcha_token,
        }))
        .send().await
        .map_err(|e| format!("Network error: {}", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();

    if !status.is_success() {
        log::error!("Registration failed: {}", body);
        return Err(format!("Registration failed: {}", body));
    }

    // Parse the JSON response
    let result: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| format!("JSON parse error: {}", e))?;

    log::info!("Registration response: {}", result);

    // Extract user_id and message from the new flow
    let user_id = result["user_id"].as_str().map(|s| s.to_string());
    let resp_email = result["email"].as_str().map(|s| s.to_string());
    let message = result["message"].as_str().unwrap_or("Registration successful. Check your email for the verification code.").to_string();

    Ok(RegisterResponse {
        success: true,
        user_id,
        email: resp_email,
        message,
    })
}

#[tauri::command]
pub async fn verify_email(
    user_id: String,
    code: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let server_url = get_server_url(&conn).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/verify_email", server_url))
        .json(&serde_json::json!({
            "user_id": user_id,
            "code": code,
        }))
        .send().await
        .map_err(|e| format!("Network error: {}", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    if status.is_success() {
        Ok(GenericResponse {
            success: true,
            message: result.message.unwrap_or("Email verified successfully.".to_string()),
        })
    } else {
        Err(result.error.unwrap_or(format!("Verification failed: {}", status)))
    }
}

#[tauri::command]
pub async fn resend_otp(
    user_id: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let server_url = get_server_url(&conn).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/resend_otp", server_url))
        .json(&serde_json::json!({ "user_id": user_id }))
        .send().await
        .map_err(|e| format!("Network error: {}", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    if status.is_success() {
        Ok(GenericResponse {
            success: true,
            message: result.message.unwrap_or("New code sent.".to_string()),
        })
    } else {
        Err(result.error.unwrap_or(format!("Resend failed: {}", status)))
    }
}

#[tauri::command]
pub async fn forgot_password(
    email: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let server_url = get_server_url(&conn).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/forgot_password", server_url))
        .json(&serde_json::json!({ "email": email }))
        .send().await
        .map_err(|e| format!("Network error: {}", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    // Always returns 200 OK with generic message to prevent enumeration, according to controller logic
    Ok(GenericResponse {
        success: status.is_success(),
        message: result.message.unwrap_or("If that email is registered, a reset link has been sent.".to_string()),
    })
}

#[tauri::command]
pub async fn reset_password(
    user_id: String,
    token: String,
    password: String,
    confirm: String,
    state: State<'_, AppState>,
) -> Result<GenericResponse, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let server_url = get_server_url(&conn).await;

    let resp = reqwest::Client::new()
        .post(format!("{}/api/v1/account/reset_password", server_url))
        .json(&serde_json::json!({
            "user_id": user_id,
            "token": token,
            "password": password,
            "password_confirmation": confirm
        }))
        .send().await
        .map_err(|e| format!("Network error: {}", e))?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let result: ApiMessageResponse = serde_json::from_str(&body).unwrap_or(ApiMessageResponse { message: None, error: Some(body.clone()), user_id: None, email: None });

    if status.is_success() {
        Ok(GenericResponse {
            success: true,
            message: result.message.unwrap_or("Password reset successfully.".to_string()),
        })
    } else {
        Err(result.error.unwrap_or(format!("Reset failed: {}", status)))
    }
}

#[tauri::command]
pub async fn get_stored_did(state: State<'_, AppState>) -> Result<Option<String>, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;

    let mut rows = conn
        .query("SELECT did FROM local_identity WHERE id = 'singleton'", ())
        .await.map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => Ok(Some(s)),
            _ => Ok(None),
        }
    } else {
        Ok(None)
    }
}

#[tauri::command]
pub async fn login(
    identifier: String,
    password: String,
    state: State<'_, AppState>,
) -> Result<LoginResponse, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let server_url = get_server_url(&conn).await;

    log::info!("Login: {} @ {}", identifier, server_url);

    let client = reqwest::Client::new();

    let token_resp = client
        .post(format!("{}/api/v1/oauth/token", server_url))
        .json(&serde_json::json!({
            "grant_type": "password",
            "username":   identifier,
            "password":   password,
        }))
        .send().await
        .map_err(|e| format!("Network error: {}", e))?;

    if !token_resp.status().is_success() {
        let status = token_resp.status();
        let body   = token_resp.text().await.unwrap_or_default();
        log::error!("Token request failed: {} - {}", status, body);
        return Err(format!("Login failed: {} {}", status, body));
    }

    let token_data: serde_json::Value = token_resp.json().await
        .map_err(|e| format!("Failed to parse token response: {}", e))?;

    log::info!("Token response: {}", token_data);

    let access_token = token_data["access_token"]
        .as_str()
        .ok_or_else(|| format!("No access_token in response: {}", token_data))?
        .to_string();

    let did: String =
        if let Some(d) = token_data["did"].as_str().filter(|s| s.starts_with("did:")) {
            d.to_string()
        }
        else if let Some(d) = token_data["account"]["did"].as_str().filter(|s| s.starts_with("did:")) {
            d.to_string()
        }
        else if let Some(me) = token_data["me"].as_str() {
            if me.starts_with("did:") {
                me.to_string()
            } else {
                let segment = me.trim_end_matches('/').split('/').last().unwrap_or(&identifier);
                format!("did:przma:{}", segment)
            }
        }
        else if let Some(id) = token_data["account"]["id"].as_str() {
            format!("did:przma:{}", id)
        }
        else if let Some(id) = token_data["account"]["id"].as_i64() {
            format!("did:przma:{}", id)
        }
        else {
            format!("did:przma:{}", identifier)
        };

    let username = token_data["account"]["username"].as_str()
        .or_else(|| token_data["account"]["acct"].as_str())
        .unwrap_or(&identifier)
        .to_string();

    let user_id = did.splitn(3, ':').nth(2).unwrap_or(&identifier).to_string();

    let _sqld_url = token_data["sync_config"]["sqld_url"].as_str().map(|s| s.to_string());
    let _s3_bucket = token_data["sync_config"]["s3_bucket"].as_str().map(|s| s.to_string());
    let _s3_prefix = token_data["sync_config"]["s3_prefix"].as_str().map(|s| s.to_string());

    log::info!("Login OK  username={} did={} user_id={}", username, did, user_id);

    conn.execute(
        "INSERT INTO local_identity (
            id, did, user_id, username, access_token, server_url, updated_at
         ) VALUES (
            'singleton', ?, ?, ?, ?, ?, datetime('now')
         )
         ON CONFLICT(id) DO UPDATE SET
            did          = excluded.did,
            user_id      = excluded.user_id,
            username     = excluded.username,
            access_token = excluded.access_token,
            server_url   = excluded.server_url,
            updated_at   = excluded.updated_at",
        libsql::params![did.clone(), user_id, username, access_token.clone(), server_url],
    )
    .await
    .map_err(|e| format!("Failed to save credentials: {}", e))?;
    log::info!("Credentials saved");

    Ok(LoginResponse {
        success:      true,
        did:          Some(did),
        access_token: Some(access_token),
    })
}

#[tauri::command]
pub async fn logout(state: State<'_, AppState>) -> Result<(), String> {
    log::info!("Logout");

    let conn = state.db.connect().map_err(|e| e.to_string())?;

    conn.execute(
        "UPDATE local_identity SET
            did          = NULL,
            user_id      = NULL,
            username     = NULL,
            email        = NULL,
            access_token = NULL,
            sqld_url     = NULL,
            s3_bucket    = NULL,
            s3_prefix    = NULL,
            last_sync_at = NULL,
            updated_at   = datetime('now')
         WHERE id = 'singleton'",
        (),
    )
    .await
    .map_err(|e| format!("Database error: {}", e))?;

    conn.execute("DELETE FROM documents", ())
        .await
        .map_err(|e| format!("Failed to clear documents: {}", e))?;

    log::info!("Logout successful and local data cleared");
    Ok(())
}