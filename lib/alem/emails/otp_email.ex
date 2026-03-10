defmodule Alem.Emails.OTPEmail do
  @moduledoc """
  Production email templates for OTP verification and password reset.
  """
  import Swoosh.Email

  @app_name     "PRZMA / ALEM"
  @from_email   "noreply@przma.com"
  @support_email "support@przma.com"

  # ---------------------------------------------------------------------------
  # Verification email
  # ---------------------------------------------------------------------------

  @doc """
  Send a 6-digit OTP verification email.

  Options:
    - name:            recipient's display name (default: "there")
    - expires_minutes: code expiry label (default: 10)
  """
  def verification_email(user_email, otp_code, opts \\ []) do
    name            = Keyword.get(opts, :name, "there")
    expires_minutes = Keyword.get(opts, :expires_minutes, 10)

    new()
    |> to(user_email)
    |> from({@app_name, @from_email})
    |> reply_to(@support_email)
    |> subject("#{otp_code} is your ALEM verification code")
    |> html_body(verification_html(name, otp_code, expires_minutes))
    |> text_body(verification_text(name, otp_code, expires_minutes))
    |> header("X-Mailer", "ALEM/1.0")
    |> header("X-Priority", "1")
    |> header("Precedence", "transactional")
  end

  # ---------------------------------------------------------------------------
  # Password reset email
  # ---------------------------------------------------------------------------

  @doc """
  Send a password reset email with a signed URL.

  Options:
    - name:      recipient's display name
    - reset_url: the full reset link
  """
  def password_reset_email(user_email, opts \\ []) do
    name      = Keyword.get(opts, :name, "there")
    reset_url = Keyword.get(opts, :reset_url, "#")

    new()
    |> to(user_email)
    |> from({@app_name, @from_email})
    |> reply_to(@support_email)
    |> subject("Reset your ALEM password")
    |> html_body(reset_html(name, reset_url))
    |> text_body(reset_text(name, reset_url))
    |> header("X-Mailer", "ALEM/1.0")
    |> header("Precedence", "transactional")
  end

  # ---------------------------------------------------------------------------
  # Private: verification HTML
  # ---------------------------------------------------------------------------

  defp verification_html(name, otp_code, expires_minutes) do
    year = Date.utc_today().year

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width,initial-scale=1.0">
      <title>Verify Your Email — ALEM</title>
    </head>
    <body style="margin:0;padding:0;background:#f1f5f9;font-family:Arial,Helvetica,sans-serif;">
      <table width="100%" cellpadding="0" cellspacing="0" role="presentation"
             style="background:#f1f5f9;padding:48px 0;">
        <tr><td align="center">

          <table width="560" cellpadding="0" cellspacing="0" role="presentation"
                 style="background:#ffffff;border-radius:12px;overflow:hidden;
                        box-shadow:0 4px 16px rgba(0,0,0,0.08);">

            <!-- ── Header ── -->
            <tr>
              <td style="background:#0f172a;padding:28px 40px;">
                <table width="100%" cellpadding="0" cellspacing="0" role="presentation">
                  <tr>
                    <td>
                      <span style="color:#ffffff;font-size:20px;font-weight:700;
                                   letter-spacing:0.5px;">PRZMA</span>
                      <span style="color:#94a3b8;font-size:20px;font-weight:400;
                                   margin-left:6px;">/ ALEM</span>
                    </td>
                    <td align="right">
                      <span style="color:#64748b;font-size:12px;">Email Verification</span>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>

            <!-- ── Body ── -->
            <tr>
              <td style="padding:40px 40px 32px;">

                <p style="margin:0 0 8px;color:#0f172a;font-size:18px;font-weight:600;">
                  Hi #{name},
                </p>
                <p style="margin:0 0 28px;color:#475569;font-size:15px;line-height:1.7;">
                  Enter the code below in the app to verify your email address
                  and complete your ALEM registration.
                </p>

                <!-- OTP block -->
                <table width="100%" cellpadding="0" cellspacing="0" role="presentation">
                  <tr>
                    <td align="center"
                        style="background:#f8fafc;border:2px dashed #cbd5e1;
                               border-radius:10px;padding:32px 24px;">
                      <p style="margin:0 0 10px;color:#94a3b8;font-size:11px;
                                text-transform:uppercase;letter-spacing:3px;font-weight:600;">
                        Verification Code
                      </p>
                      <p style="margin:0;color:#0f172a;font-size:44px;font-weight:800;
                                letter-spacing:14px;font-family:'Courier New',Courier,monospace;">
                        #{otp_code}
                      </p>
                    </td>
                  </tr>
                </table>

                <!-- Warnings -->
                <table width="100%" cellpadding="0" cellspacing="0" role="presentation"
                       style="margin-top:24px;">
                  <tr>
                    <td style="background:#fef9c3;border-left:4px solid #eab308;
                               border-radius:4px;padding:12px 16px;">
                      <p style="margin:0;color:#713f12;font-size:13px;line-height:1.6;">
                        ⏱ This code expires in <strong>#{expires_minutes} minutes</strong>.<br>
                        🔒 <strong>Never share this code.</strong> ALEM staff will never ask for it.
                      </p>
                    </td>
                  </tr>
                </table>

              </td>
            </tr>

            <!-- ── Footer ── -->
            <tr>
              <td style="background:#f8fafc;border-top:1px solid #e2e8f0;
                         padding:20px 40px;">
                <p style="margin:0;color:#94a3b8;font-size:12px;line-height:1.6;">
                  If you did not create an ALEM account, you can safely ignore this email —
                  no action is needed.<br><br>
                  © #{year} PRZMA. All rights reserved. ·
                  <a href="mailto:support@przma.com"
                     style="color:#94a3b8;">support@przma.com</a>
                </p>
              </td>
            </tr>

          </table>
        </td></tr>
      </table>
    </body>
    </html>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: verification plain text
  # ---------------------------------------------------------------------------

  defp verification_text(name, otp_code, expires_minutes) do
    """
    PRZMA / ALEM — Email Verification
    ===================================

    Hi #{name},

    Your verification code is:

        #{otp_code}

    This code expires in #{expires_minutes} minutes.

    SECURITY: NEVER share this code with anyone.
    ALEM staff will never ask for your verification code.

    If you did not register for ALEM, ignore this email.

    ─────────────────────────────────────
    © #{Date.utc_today().year} PRZMA · support@przma.com
    """
  end

  # ---------------------------------------------------------------------------
  # Private: password reset HTML
  # ---------------------------------------------------------------------------

  defp reset_html(name, reset_url) do
    year = Date.utc_today().year

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width,initial-scale=1.0">
      <title>Reset Your Password — ALEM</title>
    </head>
    <body style="margin:0;padding:0;background:#f1f5f9;font-family:Arial,Helvetica,sans-serif;">
      <table width="100%" cellpadding="0" cellspacing="0" role="presentation"
             style="background:#f1f5f9;padding:48px 0;">
        <tr><td align="center">

          <table width="560" cellpadding="0" cellspacing="0" role="presentation"
                 style="background:#ffffff;border-radius:12px;overflow:hidden;
                        box-shadow:0 4px 16px rgba(0,0,0,0.08);">

            <tr>
              <td style="background:#0f172a;padding:28px 40px;">
                <span style="color:#ffffff;font-size:20px;font-weight:700;">PRZMA</span>
                <span style="color:#94a3b8;font-size:20px;margin-left:6px;">/ ALEM</span>
              </td>
            </tr>

            <tr>
              <td style="padding:40px;">
                <p style="margin:0 0 8px;color:#0f172a;font-size:18px;font-weight:600;">
                  Hi #{name},
                </p>
                <p style="margin:0 0 28px;color:#475569;font-size:15px;line-height:1.7;">
                  Click the button below to reset your password securely in the ALEM app.
                </p>

                <!-- BUTTON -->
                <table cellpadding="0" cellspacing="0" role="presentation" style="margin:0 0 28px;">
                  <tr>
                    <td style="background:#0f172a;border-radius:8px;">
                      <a href="#{reset_url}"
                         style="display:inline-block;color:#ffffff;text-decoration:none;
                                font-size:15px;font-weight:600;padding:14px 32px;">
                        Reset Password →
                      </a>
                    </td>
                  </tr>
                </table>

                <table width="100%" cellpadding="0" cellspacing="0" role="presentation">
                  <tr>
                    <td style="background:#fef2f2;border-left:4px solid #ef4444;border-radius:4px;padding:12px 16px;">
                      <p style="margin:0;color:#7f1d1d;font-size:13px;line-height:1.6;">
                        If you did not request a password reset, ignore this email.
                      </p>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>

            <tr>
              <td style="background:#f8fafc;border-top:1px solid #e2e8f0;padding:20px 40px;">
                <p style="margin:0;color:#94a3b8;font-size:12px;line-height:1.6;">
                  © #{year} PRZMA. All rights reserved.
                </p>
              </td>
            </tr>

          </table>
        </td></tr>
      </table>
    </body>
    </html>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: password reset plain text
  # ---------------------------------------------------------------------------

  defp reset_text(name, reset_url) do
    """
    PRZMA / ALEM — Password Reset
    ==============================

    Hi #{name},

    Reset your ALEM password here:

        #{reset_url}

    This link expires in 15 minutes.

    If you did not request a password reset, ignore this email.
    Your password will not be changed.

    ─────────────────────────────────────
    © #{Date.utc_today().year} PRZMA · support@przma.com
    """
  end
end
