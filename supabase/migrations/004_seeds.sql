-- ==============================================================================
-- LATIDO - Migración 004: Plantillas Semilla de Modo Rescate
-- ==============================================================================

-- Plantillas por defecto del sistema (business_id IS NULL)
INSERT INTO public.rescue_templates (business_id, stars, channel, subject, body)
VALUES
-- WhatsApp 1★
(NULL, 1, 'whatsapp', NULL, 
    'Hola {nombre}, soy {encargado} de {negocio}. Vi tu opinión y lamento muchísimo que tu experiencia haya sido tan mala; no es lo que queremos para nadie que nos visita. Me gustaría escucharte personalmente y encontrar la forma de solucionarlo. ¿Tenés unos minutos para hablar?'),

-- WhatsApp 2★
(NULL, 2, 'whatsapp', NULL, 
    'Hola {nombre}, soy {encargado} de {negocio}. Gracias por dejarnos tu opinión. Lamento que tu experiencia no haya estado a la altura. Me gustaría entender qué pasó para poder mejorarlo y compensarte como corresponde. ¿Me contás un poco más?'),

-- WhatsApp 3★
(NULL, 3, 'whatsapp', NULL, 
    'Hola {nombre}, soy {encargado} de {negocio}. Gracias por tu opinión, nos ayuda un montón. Sentimos que todavía podemos hacerlo mejor. ¿Qué te faltó para que tu experiencia hubiera sido excelente?'),

-- Email 1★
(NULL, 1, 'email', 'Sobre tu visita a {negocio}', 
    'Hola {nombre},\n\nSoy {encargado} de {negocio}. Vi tu opinión y lamento muchísimo que tu experiencia haya sido tan mala; no es lo que queremos para nadie que nos visita.\n\nMe gustaría escucharte personalmente y encontrar la forma de solucionarlo. ¿Tenés unos minutos para responder este correo o coordinar una llamada?\n\nAtentamente,\n{encargado} — {negocio}'),

-- Email 2★
(NULL, 2, 'email', 'Sobre tu visita a {negocio}', 
    'Hola {nombre},\n\nSoy {encargado} de {negocio}. Gracias por dejarnos tu opinión. Lamento que tu experiencia no haya estado a la altura de lo esperado.\n\nMe gustaría entender qué pasó para poder mejorarlo y compensarte como corresponde. ¿Podrías contarnos un poco más?\n\nAtentamente,\n{encargado} — {negocio}'),

-- Email 3★
(NULL, 3, 'email', 'Gracias por tu visita a {negocio}', 
    'Hola {nombre},\n\nSoy {encargado} de {negocio}. Gracias por tu opinión, nos ayuda un montón. Sentimos que todavía podemos hacerlo mejor.\n\n¿Qué te faltó para que tu experiencia hubiera sido excelente?\n\nAtentamente,\n{encargado} — {negocio}')

ON CONFLICT DO NOTHING;
